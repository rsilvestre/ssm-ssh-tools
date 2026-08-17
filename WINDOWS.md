# Windows

Three ways to run this on Windows. The PowerShell script is the only one needing
nothing extra installed; WSL2 is the closest to the macOS/Linux experience.

| Route | Needs | Script to use |
|---|---|---|
| [PowerShell](#powershell-native) | nothing extra | `ssm-instances.ps1` |
| [WSL2](#wsl2) | WSL2 + a distro | `ssm-instances.sh` |
| [Git Bash](#git-bash) | Git for Windows | `ssm-instances.sh` |

> **Status: untested on Windows.** The PowerShell port and the ProxyCommand forms
> below were written by mirroring the bash version, but have not been run on a
> Windows machine. The ssh-config parser was verified to select the same hosts as
> the bash implementation. Please report anything that misbehaves.

## Prerequisites (all routes)

- [AWS CLI v2 for Windows](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [Session Manager plugin for Windows](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- An OpenSSH client. Windows 10 1809+ ships one at
  `C:\Windows\System32\OpenSSH\ssh.exe`; check with `ssh -V`.

Confirm both tools are on `PATH` before anything else — most failures here are a
missing `session-manager-plugin`:

```powershell
aws --version
session-manager-plugin --version
```

## The ProxyCommand on Windows

The macOS PATH problem does **not** apply — Windows GUI apps inherit the system
and user `PATH`, so an editor sees the same `PATH` your terminal does. What bites
instead is that `sh -c` does not exist natively, and Windows paths contain spaces
and backslashes.

Use the plain form, with no shell wrapper:

```
Host myproject-dev
  HostName i-0123456789abcdef0
  User ec2-user
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters "portNumber=%p"
```

Your ssh config lives at `C:\Users\<you>\.ssh\config`.

Note what this form gives up: without a shell there is no
`|| aws sso login` fallback, so an expired token produces a failed connection
rather than a login prompt. Refresh it yourself when that happens:

```powershell
aws sso login --profile my-profile
```

Set the profile and region per-host instead of via `export`:

```
Host myproject-dev
  HostName i-0123456789abcdef0
  User ec2-user
  SetEnv AWS_PROFILE=my-profile AWS_REGION=eu-west-1
  ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters "portNumber=%p"
```

`SetEnv` needs OpenSSH 8.0+ (`ssh -V` to check). On older builds, put the profile
in the ProxyCommand instead:

```
  ProxyCommand aws ssm start-session --profile my-profile --region eu-west-1 --target %h --document-name AWS-StartSSHSession --parameters "portNumber=%p"
```

If you would rather keep the `sso login` fallback, invoke a shell explicitly —
this needs Git for Windows installed:

```
  ProxyCommand "C:\Program Files\Git\bin\sh.exe" -c "export AWS_PROFILE=my-profile; export AWS_REGION=eu-west-1; aws sts get-caller-identity >/dev/null 2>&1 || aws sso login --profile my-profile >&2; exec aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
```

The `>&2` still matters for exactly the reason it does on macOS: a ProxyCommand's
stdout is the SSH wire, and a login banner written there corrupts the handshake.

## PowerShell (native)

Works in Windows PowerShell 5.1 and PowerShell 7+.

```powershell
git clone https://github.com/rsilvestre/ssm-ssh-tools.git
cd ssm-ssh-tools
.\ssm-instances.ps1 list
```

Scripts are blocked by default. Either allow local scripts once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

…or unblock just this file:

```powershell
Unblock-File .\ssm-instances.ps1
```

Usage mirrors the bash version:

```powershell
.\ssm-instances.ps1                      # pick a host, flip its state
.\ssm-instances.ps1 start                # picker, start only
.\ssm-instances.ps1 stop                 # picker, stop only
.\ssm-instances.ps1 list                 # table of EC2 + SSM state
.\ssm-instances.ps1 start myproject-dev  # skip the picker
.\ssm-instances.ps1 stop  myproject-dev
.\ssm-instances.ps1 hosts                # host<TAB>instance<TAB>profile
```

There is no `fzf` dependency; the picker is always the numbered menu. Config is
by environment variable, same names as the bash version:

```powershell
$env:SSM_REGION = 'eu-west-1'
$env:SSM_HOST_PREFIX = 'myproject-'
$env:SSM_SSH_CONFIG = "$HOME\.ssh\config"
```

A convenience function for your profile (`notepad $PROFILE`):

```powershell
function inst { & "$HOME\git\ssm-ssh-tools\ssm-instances.ps1" @args }
```

Differences from the bash version, all cosmetic:

- Parallel lookups use `Start-Job`, which spins up child runspaces. That has a
  higher fixed startup cost than bash subshells, so `list` may not be as fast a
  win over serial as the ~5x seen on macOS.
- Interactivity is detected with `[Environment]::UserInteractive` rather than a
  tty check.

## WSL2

The bash script runs unmodified inside WSL2, which is the best option if you
already use it.

```bash
sudo apt install -y awscli fzf     # or install AWS CLI v2 per AWS docs
./ssm-instances.sh list
```

Two things to know:

**WSL has its own filesystem and its own `~/.ssh/config`.** To share the Windows
one, point the script at it:

```bash
export SSM_SSH_CONFIG=/mnt/c/Users/<you>/.ssh/config
```

Symlinking (`ln -s /mnt/c/Users/<you>/.ssh ~/.ssh`) also works, but Windows-side
permissions can make ssh reject key files as too open. Copying the config in and
keeping keys on the Linux side is more reliable.

**Install the AWS CLI and Session Manager plugin inside WSL**, not just on
Windows — the Linux binaries are what the WSL script invokes.

## Git Bash

The bash script also runs under Git Bash, with two caveats worth knowing before
you rely on it:

- `Start-Job`-style parallelism is fine (Git Bash has real subshells), but
  process creation on Windows is slow, so `list` will be noticeably slower than
  on macOS or WSL.
- Git Bash mangles arguments that look like paths. The script does not pass any,
  but if you hit odd behaviour, prefix the command with `MSYS_NO_PATHCONV=1`.

```bash
MSYS_NO_PATHCONV=1 ./ssm-instances.sh list
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `SessionManagerPlugin is not found` | plugin not installed, or not on `PATH`. Reopen the terminal after installing — `PATH` changes need a fresh process. |
| `aws : The term 'aws' is not recognized` | AWS CLI not on `PATH`; reopen the terminal after install. |
| `.ps1 cannot be loaded because running scripts is disabled` | see the execution-policy note above |
| `Connection closed by UNKNOWN port 65535` | expired token (no shell fallback in the plain ProxyCommand — run `aws sso login`), or the instance is not connected |
| `Host key verification failed` | first connect to a new instance id; `ssh -o StrictHostKeyChecking=accept-new <host>` once |
| ssh works in terminal, fails in VS Code | unlike macOS this is usually **not** `PATH`. Check the editor was fully restarted, and that it is not using a bundled ssh — set `remote.SSH.path` to `C:\Windows\System32\OpenSSH\ssh.exe`. |
