# SSH into private EC2 instances without a bastion

*Using AWS Systems Manager — and the one gotcha that makes it fail in VS Code and Cursor while working fine in your terminal.*

---

If you run EC2 instances in private subnets, you have probably paid for a bastion host: a small box with a public IP whose only job is to be the thing you SSH into first. It needs patching. It needs its security group audited. It is a permanently open door on the internet, and it exists solely so you can reach machines that are deliberately unreachable.

AWS Systems Manager removes the need for it. Session Manager tunnels SSH through the SSM agent already running on your instances, so you can `ssh myproject-dev` and land on a box with no public IP, no inbound rule on port 22, and no bastion in between. Authentication is IAM. The tunnel is auditable in CloudTrail.

Setting it up is about six lines of config. What is not obvious — and what cost me an afternoon — is that the naive setup works perfectly from a terminal and fails in VS Code Remote-SSH or Cursor, with an error that points nowhere useful.

This walks through a working setup, then explains each piece of the incantation and why it is shaped that way.

## What you need

- **AWS CLI v2** — [install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **Session Manager plugin** — [install guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html). A separate download from the CLI, and the single most common cause of failure here.
- **An instance running the SSM agent**, with an instance profile including `AmazonSSMManagedInstanceCore`. Amazon Linux 2/2023 and recent Ubuntu images ship the agent preinstalled.
- **IAM permissions** for `ssm:StartSession` on the instance and the `AWS-StartSSHSession` document.

Check the instance is actually registered before touching any config:

```sh
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-0123456789abcdef0" \
  --query 'InstanceInformationList[0].PingStatus' --output text
```

You want `Online`. If you get nothing back, the instance is stopped, the agent is not running, or the instance role is missing — fix that first, because no amount of SSH config will help.

## The config

One block in `~/.ssh/config`:

```
Host myproject-dev
  HostName i-0123456789abcdef0
  User ec2-user
  ProxyCommand sh -c "export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin; export AWS_PROFILE=my-profile; export AWS_REGION=eu-west-1; aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile my-profile >&2; exec aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
```

Then:

```sh
ssh myproject-dev
```

Note the `HostName` is the **instance ID**, not a hostname. OpenSSH substitutes it into `%h`, so `--target` receives the instance ID that Session Manager expects. `%p` is the port.

That one line is doing four separate jobs. Each defends against a specific failure, and three of them produce the *same* unhelpful error:

```
Connection closed by UNKNOWN port 65535
```

Worth understanding before you find out the hard way.

## Gotcha 1: it works in your terminal, fails in your editor

This is the one that costs people an afternoon.

You get it working in a terminal. You point Cursor or VS Code Remote-SSH at the same host. It fails:

```
aws: [ERROR]: SessionManagerPlugin is not found.
Connection closed by UNKNOWN port 65535
```

The plugin *is* installed. The exact same command works one window over.

The cause: **GUI applications on macOS do not inherit your shell's `PATH`.** An app launched from the Dock gets a minimal `PATH` — typically `/usr/bin:/bin:/usr/sbin:/sbin`. Your shell's `PATH`, with `/opt/homebrew/bin` and `/usr/local/bin` on it, is assembled by `~/.zshrc`, which a GUI app never sources. So when the editor runs your ProxyCommand, `session-manager-plugin` is not findable.

The trap: the obvious fix does not work. Writing an absolute path to `aws` seems like it should solve it:

```
ProxyCommand /opt/homebrew/bin/aws ssm start-session ...
```

It does not. The AWS CLI finds `aws` fine — then does its *own* `PATH` lookup for `session-manager-plugin`, as a separate search. Fixing the first path leaves the second broken, which is why this one is so confusing to debug: you fixed the path and the error did not change.

The fix is to set `PATH` inside the ProxyCommand, covering wherever the plugin actually lives:

```
export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

Intel Homebrew uses `/usr/local/bin`, Apple Silicon `/opt/homebrew/bin`; the plugin's own installer defaults to `/usr/local/bin`. Listing all of them costs nothing.

### Testing it without restarting your editor

Restarting an editor to test a config change is a slow loop. Reproduce its environment directly instead:

```sh
env -i HOME="$HOME" USER="$USER" SSH_AUTH_SOCK="$SSH_AUTH_SOCK" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/ssh -o BatchMode=yes myproject-dev hostname
```

`env -i` clears the environment, then puts back only what a GUI app would have. If this succeeds, your editor will too.

Keep `SSH_AUTH_SOCK`. Drop it and you get `Permission denied (publickey)` — an agent-forwarding failure that looks nothing like a ProxyCommand problem and will send you down the wrong path. I know because I did exactly that.

## Gotcha 2: ssh prepends `exec`

The natural way to write a multi-statement ProxyCommand fails:

```
ProxyCommand export PATH=/usr/local/bin:$PATH; exec aws ssm start-session ...
```

```
export: not a valid identifier
```

OpenSSH runs a ProxyCommand as `exec <your command>`. Your line becomes `exec export PATH=...`, and `exec` expects a program, not a shell builtin.

Wrap it in `sh -c "..."` so those statements get a shell to run in. This is why the working config has that wrapper — it is not stylistic.

## Gotcha 3: use a literal PATH, never `$PATH`

This looks tidier and is a latent bug:

```sh
export PATH="/opt/homebrew/bin:$PATH"    # don't
```

If any existing `PATH` entry contains a space — and on macOS one probably does, something like `/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin` — the expansion word-splits and `export` fails.

Worse, it fails *only for people whose `PATH` happens to contain a space*, which makes it look intermittent. Spell the `PATH` out literally.

## Gotcha 4: a ProxyCommand's stdout is the SSH wire

This one is genuinely nasty.

Adding an auto-login so an expired SSO token refreshes itself is a good idea:

```sh
aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile my-profile
```

But `aws sso login` prints a banner to **stdout** — and a ProxyCommand's stdout *is the SSH connection*. Anything written there is injected into the protocol stream, and the handshake dies:

```
Connection closed by UNKNOWN port 65535
```

Same error as several unrelated failures, with no hint that a login banner caused it.

Redirect it to stderr:

```sh
... || aws sso login --profile my-profile >&2
```

You still see the prompt; it just no longer corrupts the tunnel. This applies to *anything* you add to a ProxyCommand — every `echo` needs `>&2`.

## Errors you will actually see

| Error | Cause |
|---|---|
| `SessionManagerPlugin is not found` | `PATH` — gotcha 1 |
| `export: not a valid identifier` | missing `sh -c` — gotcha 2 |
| `Connection closed by UNKNOWN port 65535` | stdout pollution (gotcha 4), or the target is not connected |
| `TargetNotConnected` | instance stopped, agent down, or still booting |
| `Host key verification failed` | first connect to a new instance ID — see below |
| `Token has expired and refresh failed` | run `aws sso login --profile <profile>` |

After editing `~/.ssh/config`, **fully quit your editor** (⌘Q — closing the window is not enough) so a new process picks up the change. The Remote-SSH output panel is append-only, so check timestamps before concluding anything from what it shows; stale entries look identical to fresh ones.

## Two things that will bite you later

**`Online` does not mean connectable.** After starting an instance, the SSM agent registers with the control plane slightly *before* it can accept sessions. So `describe-instance-information` says `Online` and your SSH still fails with `TargetNotConnected`. It is not broken — wait fifteen seconds and retry. Any automation you write around this needs to retry rather than trust the first answer.

**Host keys change with instance IDs.** Point a host entry at a new instance and SSH refuses to connect, because the key does not match what is in `known_hosts`. Under `BatchMode=yes` — which any script uses — it fails outright rather than prompting. Use `accept-new`, which trusts a first-time key but still refuses a *changed* key on a host you already know:

```sh
ssh -o StrictHostKeyChecking=accept-new myproject-dev
```

## Windows is a different problem

If you are on Windows, most of the above does not apply — the failure mode is different, not merely relocated.

**The `PATH` gotcha does not exist.** Windows GUI applications inherit the system and user `PATH`, so your editor sees the same `PATH` your terminal does. The whole reason for gotcha 1 evaporates.

**But `sh -c` does not exist natively**, so the wrapper has to go:

```
Host myproject-dev
  HostName i-0123456789abcdef0
  User ec2-user
  ProxyCommand aws ssm start-session --profile my-profile --region eu-west-1 --target %h --document-name AWS-StartSSHSession --parameters "portNumber=%p"
```

That costs you the `|| aws sso login` fallback: with no shell, there is nowhere to put the `||`. An expired token becomes a failed connection instead of a login prompt, and you refresh it manually. If you want the fallback back, point the ProxyCommand at Git for Windows' `sh.exe` explicitly.

And when SSH works in a Windows terminal but fails in VS Code, it is usually *not* `PATH` — check the editor is not using a bundled SSH client, by setting `remote.SSH.path` to `C:\Windows\System32\OpenSSH\ssh.exe`.

## Starting the instances

A side effect of moving off bastions: dev boxes get stopped to save money, and starting one means finding its instance ID in the console, starting it, then waiting an unknown amount of time before SSH works.

I wrote a small tool for this — [ssm-ssh-tools](https://github.com/rsilvestre/ssm-ssh-tools). It reads host, instance ID, and profile out of `~/.ssh/config`, so there is no second inventory to maintain:

```
$ ./ssm-instances.sh list
HOST                               INSTANCE              EC2          SSM
myproject-dev                      i-0123456789abcdef0   running      Online
myproject-staging                  i-0fedcba987654321f   stopped      -
```

Run it bare and it shows the table, lets you pick a host, and flips its state — starting a stopped one, or stopping a running one after a confirmation. It waits for SSM registration and retries the SSH check, because of the `Online`-is-not-connectable lag above. There is a bash version and a PowerShell port.

### What porting it to Windows revealed

The most useful bug came from running it somewhere new. The config parser matched nothing on a Windows machine, and the reasons were not Windows-specific at all:

- It required `i-` to appear immediately after whitespace in `HostName`, so **any quoted value broke it**.
- It only recognised `AWS_PROFILE=`, never `--profile` — a form the project's own Windows documentation recommended.

Neither is a Windows quirk. Quoted values and `--profile` are perfectly legal in an SSH config on macOS and Linux too; my configs simply never used them, so the parser had only ever been tested against one dialect of a format that permits several.

Porting to a second platform is a cheap way to discover which of your assumptions were assumptions.

## Was it worth it?

For a private-subnet estate, yes. No bastion to patch, no public IP, no port 22 open to the internet, IAM instead of key distribution, and every session recorded in CloudTrail.

The setup cost is one config block per host and understanding four gotchas — three of which announce themselves with the same seven unhelpful words.

---

*The scripts and full documentation are at [github.com/rsilvestre/ssm-ssh-tools](https://github.com/rsilvestre/ssm-ssh-tools).*
