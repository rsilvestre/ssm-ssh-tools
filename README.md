# ssm-ssh-tools

SSH to private EC2 instances over AWS Systems Manager — without bastions, public
IPs, or open port 22 — plus a small tool to start and stop those instances.

Two independent parts. Take either one:

1. **[A ProxyCommand that works in GUI editors](#the-proxycommand)** — the fix for
   `SessionManagerPlugin is not found` in VS Code Remote-SSH and Cursor, when the
   very same `ssh` command works fine from your terminal.
2. **[`ssm-instances.sh`](#ssm-instancessh)** — start/stop the instances behind those
   ssh hosts, reading everything from `~/.ssh/config`.

## The ProxyCommand

Put this in `~/.ssh/config`, replacing `<profile>`, `<region>`, and the instance id:

```
Host myproject-dev
  HostName i-0123456789abcdef0
  User ec2-user
  ProxyCommand sh -c "export PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin; export AWS_PROFILE=<profile>; export AWS_REGION=<region>; aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile <profile> >&2; exec aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
```

Then `ssh myproject-dev`, and point Remote-SSH at the same host name.

Requires the [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
On Linux, adjust the PATH list to wherever your `aws` and `session-manager-plugin` live.

### Why it is written that way

Each piece defends against a specific failure. All four are easy to get wrong, and
three of them produce the *same* unhelpful error: `Connection closed by UNKNOWN port 65535`.

**1. `export PATH=...` — the GUI-editor fix.**
Apps launched from the macOS Dock inherit a minimal `PATH` of
`/usr/bin:/bin:/usr/sbin:/sbin` — no `/usr/local/bin`, no `/opt/homebrew/bin`.
Your shell's PATH comes from `~/.zshrc`, which a GUI app never sources. So the AWS
CLI runs but cannot find `session-manager-plugin`, which it looks up on `PATH`:

```
aws: [ERROR]: SessionManagerPlugin is not found.
```

This is why it works in a terminal and fails in the editor. Writing `aws` as an
absolute path is *not* enough — the plugin lookup is a separate PATH search done by
the CLI itself.

**2. `sh -c "..."` — because ssh prepends `exec`.**
OpenSSH runs a ProxyCommand as `exec <your command>`. A bare multi-statement command
becomes `exec export PATH=...`, and:

```
export: not a valid identifier
```

Wrapping in `sh -c "..."` gives those statements a shell to run in.

**3. A literal PATH, never `$PATH`.**
`export PATH="/opt/homebrew/bin:$PATH"` looks tidier but breaks if any existing entry
contains a space — e.g. `/Applications/Visual Studio Code - Insiders.app/...`. The
unquoted expansion word-splits and the `export` fails. Spell the PATH out.

**4. `>&2` on `aws sso login`.**
A ProxyCommand's **stdout is the SSH wire**. Anything printed there corrupts the
handshake. `aws sso login` writes a banner to stdout, so without `>&2` an expired
token produces `Connection closed by UNKNOWN port 65535` rather than a login prompt.

### Verifying the GUI case from your terminal

Don't restart the editor just to test. Reproduce its environment directly:

```sh
env -i HOME="$HOME" USER="$USER" SSH_AUTH_SOCK="$SSH_AUTH_SOCK" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  /usr/bin/ssh -o BatchMode=yes myproject-dev hostname
```

Keep `SSH_AUTH_SOCK` — dropping it breaks agent auth and you'll misread a
`Permission denied (publickey)` as a ProxyCommand fault.

### Other errors you may hit

| Error | Cause |
|---|---|
| `SessionManagerPlugin is not found` | PATH — see gotcha 1 |
| `export: not a valid identifier` | missing `sh -c` — gotcha 2 |
| `Connection closed by UNKNOWN port 65535` | stdout pollution (gotcha 4), or the target is not connected |
| `TargetNotConnected` | instance stopped, SSM agent down, or still booting |
| `Host key verification failed` | first connection to a new instance id; use `-o StrictHostKeyChecking=accept-new` once |
| `Token has expired and refresh failed` | run `aws sso login --profile <profile>` |

After changing `~/.ssh/config`, fully quit the editor (⌘Q — closing the window is not
enough) so a new process picks up the config. The Remote-SSH output panel is
append-only; check the timestamp before concluding anything from what it shows.

## ssm-instances.sh

Starting these instances via the console means hunting for an instance id, and
sshing too early fails because the SSM agent registers a minute or two after boot.
This script handles both.

```sh
./ssm-instances.sh                 # pick a host to start (fzf, or a numbered menu)
./ssm-instances.sh start           # same -- picker, then start
./ssm-instances.sh stop            # picker, then stop
./ssm-instances.sh list            # table of EC2 state + SSM status
./ssm-instances.sh start <host>    # skip the picker
./ssm-instances.sh stop  <host>
./ssm-instances.sh hosts           # machine-readable host<TAB>instance<TAB>profile
```

Naming a host skips the picker; leaving it off brings the picker up. Without a
terminal (piped, or run from a script) the picker cannot run, so it tells you to
name a host instead of hanging.

```
$ ./ssm-instances.sh list
HOST                               INSTANCE              EC2          SSM
myproject-dev                      i-0123456789abcdef0   running      Online
myproject-staging                  i-0fedcba987654321f   stopped      -
```

Host, instance id, and AWS profile all come from `~/.ssh/config` — there is no
second inventory to maintain. A block is treated as an SSM host when it has both an
`i-*` HostName and an `AWS_PROFILE=` in its ProxyCommand; everything else is ignored.

State lookups run concurrently, and each AWS profile is checked once rather than
once per host — on an 8-host config that is the difference between ~20s and ~4s.

`start` on an instance that is already running and Online returns straight away
instead of repeating the boot wait. Otherwise it waits for the instance to run,
polls until the SSM agent registers, then verifies ssh actually works. Two details
that matter in practice:

- **`Online` does not mean sessionable.** The agent registers with the control plane
  slightly before it accepts sessions, so a first attempt can still return
  `TargetNotConnected`. The script retries instead of giving up.
- **First connection to a new instance id** would fail host key verification under
  `BatchMode`, so the check uses `accept-new` — which still refuses a *changed* key
  on a host you already know.

If credentials have expired, `start` and `stop` run `aws sso login` for the one
profile they need — the same fallback the ProxyCommand uses. It only does this with
a terminal attached, so it can never hang in a script waiting on a browser. `list`
never triggers a login; it shows `no-creds` for those rows.

### Install

```sh
git clone https://github.com/rsilvestre/ssm-ssh-tools.git
cd ssm-ssh-tools && chmod +x ssm-instances.sh
```

Optionally, in `~/.zshrc` or `~/.bashrc`:

```sh
alias inst=/path/to/ssm-ssh-tools/ssm-instances.sh
```

Needs bash, the AWS CLI v2, and the Session Manager plugin. `fzf` is optional —
without it you get a numbered menu.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `SSM_REGION` | `aws configure get region`, else `us-east-1` | AWS region |
| `SSM_HOST_PREFIX` | *(unset — matches all SSM hosts)* | only consider hosts starting with this |
| `SSM_SSH_CONFIG` | `~/.ssh/config` | path to the ssh config |

```sh
SSM_HOST_PREFIX=myproject- ./ssm-instances.sh list
```

Exit codes: `2` unknown host, `3` credentials, `4` instance missing, `5` API call
failed, `6` timed out waiting for state, `7` SSM never registered.

### IAM

Starting and stopping needs `ec2:DescribeInstances`, `ec2:StartInstances`,
`ec2:StopInstances`, and `ssm:DescribeInstanceInformation`. Connecting needs
`ssm:StartSession` on the instance and the `AWS-StartSSHSession` document. The
instance itself needs the SSM agent running and a role including
`AmazonSSMManagedInstanceCore`.

## License

MIT — see [LICENSE](LICENSE).
