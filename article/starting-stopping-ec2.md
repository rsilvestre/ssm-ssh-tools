# Start and stop your AWS dev instances from the terminal

*A small tool that reads your ssh config, so there is no second inventory — and that waits until the box is actually reachable, not merely running.*

---

Dev instances get stopped to save money. That is the right call: an idle `m5.xlarge` is about $140 a month, and nobody needs it running at 3am.

The cost lands somewhere else. Every morning you want that box back, and getting it back means: open the console, find the right instance among thirty, check you are in the right account, start it, then wait. And the waiting is the annoying part, because there is no clear signal for when it is ready. You try SSH too early, get an error, wait, try again.

I got tired of that and wrote a tool. It reads the hosts you already have in `~/.ssh/config`, shows you what is running, lets you flip one, and does not claim success until it has opened a real SSH session and got a hostname back.

```
$ ssm-instances.sh list
HOST                               INSTANCE              EC2          SSM
myproject-dev                      i-0123456789abcdef0   running      Online
myproject-staging                  i-0fedcba987654321f   stopped      -
myproject-ci                       i-0abc123def4567890   running      Online
```

It is two scripts — `ssm-instances.sh` for bash, `ssm-instances.ps1` for PowerShell — at
**[github.com/rsilvestre/ssm-ssh-tools](https://github.com/rsilvestre/ssm-ssh-tools)**.

## Your ssh config is already the inventory

The design decision everything else follows from: **there is no config file**.

Every tool like this wants you to list your instances somewhere. That list then rots — someone rebuilds a box, the ID changes, and the tool is confidently wrong.

You already maintain that list, though. It is your ssh config:

```
Host myproject-dev
  HostName i-0123456789abcdef0
  User ec2-user
  ProxyCommand sh -c "... export AWS_PROFILE=my-profile; ... aws ssm start-session ..."
```

So the tool reads that, and treats a block as one of its own when it has both an `i-*` HostName and an AWS profile. Add a host, change an instance ID, delete a box — it follows automatically, because it is reading the same file SSH reads. Nothing to keep in sync.

It also means multi-account works with no configuration at all. Each host carries its own profile, so a single table can span five AWS accounts. Mine does.

## Two state columns, because there are two ways to be down

Look at that table again. `running` is EC2. `Online` is SSM. **They are not the same thing, and the gap between them is where the time goes.**

An instance can be `running` while SSM shows `-`. The box is up, you are paying for it, and you still cannot connect — because SSH here goes through Systems Manager, and SSM only knows about instances whose agent has checked in.

Seeing both columns tells you *which* problem you have:

- `stopped` / `-` — just start it.
- `running` / `Online` — ready, go.
- `running` / `-` — the box is up but the agent is not talking to SSM. That is a configuration problem, not a patience problem. [More on that below](#when-an-instance-never-comes-online).

That third row is the one that used to cost me twenty minutes of confusion. Now it is visible at a glance.

## One command, driven by state

Run it with no arguments and it shows the table, then asks:

```
$ ssm-instances.sh
Loading instance states...
HOST                               INSTANCE              EC2          SSM
myproject-dev                      i-0123456789abcdef0   running      Online
myproject-staging                  i-0fedcba987654321f   stopped      -

 1) myproject-dev
 2) myproject-staging
toggle which number (Enter to quit)? 2
```

Pick a **stopped** host and it starts. Pick a **running** one and it stops, after a `[y/N]` confirmation — stopping disconnects whoever is working on that box, so it should never happen on a mis-keyed number.

There is no separate command to remember per direction. The state you can already see decides.

The picker also loops. After an action it pauses so you can read the result, then re-fetches the table with the new state and asks again — so starting three boxes in the morning is one command, not three. Enter or `q` leaves.

If you would rather be explicit, `start` and `stop` are single-direction and never surprise you:

```sh
ssm-instances.sh start myproject-dev   # never stops anything
ssm-instances.sh stop  myproject-dev
ssm-instances.sh start                 # picker, start-only
```

That split matters for scripting. A bare run is convenient at a keyboard; `start <host>` is predictable enough to put in a Makefile.

## It waits for connectable, not merely started

This is the part that actually saves the time.

The naive version of this script issues `start-instances`, waits for `running`, and tells you it is done. Then your SSH fails, because `running` means the hypervisor has the VM — not that the SSM agent has booted, registered, and is willing to accept a session.

So the tool does the whole loop:

1. Starts the instance and waits for EC2 to report `running`.
2. Polls SSM until the agent registers — up to three minutes, because a cold boot genuinely takes that long.
3. **Then actually tries SSH**, retrying five times at fifteen-second intervals.

That third step exists because of something worth knowing even if you never use this tool: **`Online` does not mean sessionable.** The agent registers with the SSM control plane slightly before it will accept sessions. There is a window — usually under a minute — where the API says `Online` and your connection still fails with `TargetNotConnected`.

You can watch it happen:

```
$ ssm-instances.sh start myproject-staging
myproject-staging -> i-0fedcba987654321f (my-profile), state: stopped
Starting; waiting for running state...
Running.
Waiting for SSM agent to register (up to 3 min)...
SSM: Online
Verifying ssh...
  not ready yet, retrying...
CONNECTED: ssh myproject-staging  (ip-10-0-4-112.eu-west-1.compute.internal)
```

That `not ready yet, retrying...` line is the lag, live. A script that trusted `Online` would have reported failure right there.

The last line is the point: it does not say "done", it says it opened a session and the box answered with its hostname. If it cannot connect, it tells you, rather than leaving you to find out.

And starting something already up returns immediately instead of repeating the whole wait:

```
$ ssm-instances.sh start myproject-dev
Already running and Online. Connect with: ssh myproject-dev
```

## Fast enough to actually run

The first version made three sequential AWS calls per host. On an eight-host config that is 24 round-trips at roughly 0.7s each — **over 20 seconds** to draw a table. Slow enough that I stopped running it, which defeats the point.

Two changes fixed it: check each *profile* once rather than once per host, and batch the per-host lookups by profile, since both APIs accept many instance IDs at a time.

Against my own config — eight hosts across five AWS accounts — it now takes **2.7 seconds**. That is the difference between a tool you use and one you avoid.

## Expired credentials do not stop you

If a profile's SSO token has lapsed, `start` and `stop` run `aws sso login` for the one profile they need, then verify the credentials actually work before continuing.

With one guard: only when a terminal is attached. Called from a script or a pipe, it exits with a clear message instead of blocking forever on a browser prompt nobody can answer.

`list` never triggers a login at all — it shows `no-creds` for those rows and moves on, so one stale token in one account cannot hold up the whole table.

## When an instance never comes Online

The `running` / `-` row deserves its own section, because the failure is silent and the cause is almost always one of three things.

First, the check itself:

```sh
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-0123456789abcdef0" \
  --query 'InstanceInformationList[0].PingStatus' --output text
```

**Empty output is the normal failure.** Not an error — the command succeeds and returns nothing, because SSM has no record of that instance at all.

### 1. The instance role

The agent authenticates to SSM using the IAM role attached to the instance. No role, or a role without SSM permissions, and it starts, tries to register, and fails silently.

```sh
aws ec2 describe-instances --instance-ids i-0123456789abcdef0 \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text
```

`None` means no profile attached. If one is attached, check the role behind it carries **`AmazonSSMManagedInstanceCore`** — the AWS-managed policy with exactly the permissions the agent needs.

The catch that wastes an hour: **attaching a role to a running instance does not take effect immediately.** The agent picks up credentials at startup, so it carries on failing with the old ones. Restart the agent or reboot — and note you cannot SSM in to do that, since SSM is the thing that is broken. Use EC2 Instance Connect, another SSH route, or reboot from the console.

### 2. Instance metadata

The agent reads those role credentials from the instance metadata service. If metadata is switched off, the role can be perfect and the agent still has no way to use it.

```sh
aws ec2 describe-instances --instance-ids i-0123456789abcdef0 \
  --query 'Reservations[0].Instances[0].MetadataOptions.[HttpEndpoint,HttpTokens]' \
  --output text
```

You want `enabled` and `required`. To set it:

```sh
aws ec2 modify-instance-metadata-options --instance-id i-0123456789abcdef0 \
  --http-endpoint enabled --http-tokens required --http-put-response-hop-limit 2
```

**IMDSv2 does not break the SSM agent** — worth saying plainly, because these get conflated. Hardening guides tell you to set `--http-tokens required`, and when instances then fail to register it is tempting to blame that change. Any current agent speaks v2 natively, and `required` is the posture you want: it closes the SSRF path that made v1 a liability.

What breaks the agent is `--http-endpoint disabled`. Harden by requiring tokens, not by disabling metadata.

(Containers need a hop limit of `2`; `1` is fine for a process on the host.)

### 3. No route to the SSM endpoints

A private subnet with no outbound route also produces silent non-registration. The agent needs to reach `ssm`, `ssmmessages` and `ec2messages` — so either a NAT gateway or VPC interface endpoints for those three.

This one is easy to miss, because "private subnet with no outbound route" is a perfectly reasonable configuration for everything else in your estate.

## If you are not set up for SSM yet

The tool assumes you already SSH to these instances through Systems Manager. If you do not, the short version is one ssh config block per host:

```
Host myproject-dev
  HostName i-0123456789abcdef0
  User ec2-user
  ProxyCommand sh -c "export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin; export AWS_PROFILE=my-profile; export AWS_REGION=eu-west-1; aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile my-profile >&2; exec aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
```

Then `ssh myproject-dev` reaches a box with no public IP, no open port 22, and no bastion. `HostName` is the instance ID — OpenSSH substitutes it into `%h`.

That line is dense because each part fixes something specific. The one worth knowing about, since it costs people an afternoon: if it works in your terminal but fails in VS Code or Cursor with `SessionManagerPlugin is not found`, that is the `export PATH=` at the front. GUI apps on macOS do not inherit your shell's PATH — launched from the Dock they get `/usr/bin:/bin:/usr/sbin:/sbin`, no Homebrew. And pointing at `aws` by absolute path does *not* fix it, because the CLI does its own separate PATH lookup for the plugin.

The [full breakdown of that config](https://github.com/rsilvestre/ssm-ssh-tools#the-proxycommand) — including why it needs the `sh -c` wrapper, why the PATH must be literal, and why `aws sso login` needs `>&2` — is in the repo README.

## Getting it

```sh
git clone https://github.com/rsilvestre/ssm-ssh-tools.git
cd ssm-ssh-tools && chmod +x ssm-instances.sh
alias inst=$PWD/ssm-instances.sh
```

Needs bash, the AWS CLI v2, and the Session Manager plugin. `fzf` is optional — without it you get a numbered menu. There is a PowerShell port for Windows, and it runs under WSL2 and Git Bash too.

A few things that did not fit above:

- **`SSM_HOST_PREFIX`** narrows it to one project if your ssh config has many hosts. `SSM_REGION`, `SSM_SSH_CONFIG` and `SSM_AWS_BIN` cover the rest.
- **`hosts`** emits tab-separated `host / instance / profile` for scripting against.
- **Exit codes are specific** — `3` credentials, `4` instance does not exist, `7` started but SSM never registered — so a wrapper can tell "your token expired" from "that instance is gone".
- **Host keys use `accept-new`**, so a rebuilt instance with a new ID does not fail verification under `BatchMode`, while a *changed* key on a known host still errors as it should.

---

*Scripts and full docs: [github.com/rsilvestre/ssm-ssh-tools](https://github.com/rsilvestre/ssm-ssh-tools)*
