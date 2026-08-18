# Windows

Three ways to run this on Windows. The PowerShell script is the only one needing
nothing extra installed; WSL2 is the closest to the macOS/Linux experience.

| Route | Needs | Script to use |
|---|---|---|
| [PowerShell](#powershell-native) | nothing extra | `ssm-instances.ps1` |
| [WSL2](#wsl2) | WSL2 + a distro | `ssm-instances.sh` |
| [Git Bash](#git-bash) | Git for Windows | `ssm-instances.sh` |

> **Status: partly verified.** The parser handles the Windows config dialects
> documented below — quoted `HostName`, `--profile`, CRLF line endings — each
> covered by a fixture, though those run on Linux rather than under Git Bash. The
> PowerShell port is still unrun on Windows; it mirrors the bash version rather
> than having been exercised. Please report anything that misbehaves.

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

### Without admin rights

Plenty of organisations do not let you write to `Program Files`. The two tools
differ here, so treat them separately.

**AWS CLI — no admin needed.** AWS ships a current-user install that lands in
`%LOCALAPPDATA%\Programs\Amazon\AWSCLIV2` and puts itself on your user `PATH`:

```powershell
irm https://awscli.amazonaws.com/v2/install.ps1 | iex
```

There is also a current-user MSI, and it accepts an `INSTALLDIR` if you want the
files somewhere specific — for example under your home directory:

```powershell
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2-User.msi /qn
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2-User.msi INSTALLDIR="$HOME\awscli" /qn
```

`INSTALLDIR` appends `Amazon\AWSCLIV2`, so the second command puts `aws.exe` at
`%USERPROFILE%\awscli\Amazon\AWSCLIV2\aws.exe`. Either way, update it later
with `aws update` rather than re-running the installer.

**Session Manager plugin — admin is required.** AWS states plainly that its
installer needs Administrator rights, and the `.zip` download is just the same
installer zipped, not a portable binary. There is no supported no-admin route, so
this one goes to whoever holds admin on the machine:

```
https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe
```

It installs to `%PROGRAMFILES%\Amazon\SessionManagerPlugin\bin\`, and its
install dialog accepts a different location if `Program Files` is off-limits.
Whatever directory it lands in must be on `PATH`, because the AWS CLI looks the
plugin up there itself — see [the PATH gotcha](README.md#why-it-is-written-that-way).

Until it is installed, `list`, `start`, and `stop` all work; only the ssh
connection itself fails.

### Putting a hand-installed tool on PATH

A manual install often does not touch `PATH`. To set it permanently for your user
(no admin, survives reboots — reopen the terminal afterwards):

```powershell
[Environment]::SetEnvironmentVariable(
  'PATH',
  [Environment]::GetEnvironmentVariable('PATH', 'User') + ';' + "$HOME\awscli\Amazon\AWSCLIV2",
  'User')
```

Git Bash reads that same user `PATH`. If you would rather keep it shell-local, add
this to `~/.bashrc` instead — note the Git Bash spelling of the path:

```bash
export PATH="$PATH:/c/Users/<you>/awscli/Amazon/AWSCLIV2"
```

GUI apps such as VS Code only pick up a changed user `PATH` on a full restart —
and, on some Windows builds, only after signing out and back in.

**Or skip `PATH` for the script entirely.** If `aws` is installed somewhere
awkward and you do not want to touch `PATH`, point the script straight at it:

```bash
SSM_AWS_BIN=/c/Users/<you>/awscli/Amazon/AWSCLIV2/aws ./ssm-instances.sh list
```

```powershell
$env:SSM_AWS_BIN = "$HOME\awscli\Amazon\AWSCLIV2\aws.exe"
```

This covers the script only. The ProxyCommand is run by `ssh`, not by the script,
so `ssh` itself still needs `aws` and `session-manager-plugin` on `PATH` — or an
absolute path written into the ProxyCommand.

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

Or use PowerShell as the shell, which needs nothing extra installed:

```
  ProxyCommand powershell.exe "aws --profile my-profile sts get-caller-identity > $null 2>&1; if ($LASTEXITCODE -ne 0) { aws sso login --profile my-profile | ForEach-Object { [Console]::Error.WriteLine($_) } }; aws --profile my-profile --region eu-west-1 ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
```

Mind the redirect on the login. PowerShell has no `1>&2`, so the `>&2` used in the
`sh -c` forms above does not translate, and a bare `aws sso login` inside a
ProxyCommand writes its device code and URL straight onto the SSH wire — giving
you `Connection closed by UNKNOWN port 65535` instead of a login prompt, exactly
[gotcha 4](README.md#why-it-is-written-that-way) in PowerShell dress. Piping
through `[Console]::Error.WriteLine` is the equivalent move: the code and URL
still reach your screen, on stderr, where they cannot corrupt the handshake.
`| Out-Null` also protects the wire, but then an expired token logs in silently
with nothing shown.

### What `ssm-instances` reads from these

The script treats a block as an SSM host only when it can find **both** an `i-*`
`HostName` and an AWS profile in it. Profiles are read from either spelling, so
`SetEnv AWS_PROFILE=…`, `export AWS_PROFILE=…`, `$env:AWS_PROFILE=…`, and
`--profile …` / `--profile=…` anywhere in the block all work, as do quoted values
like `HostName "i-0123456789abcdef0"`.

The one form it cannot use is the very first one on this page — the plain
ProxyCommand with no profile named anywhere, relying on `AWS_PROFILE` being set in
your environment. There is nothing in the block to read, so the script skips the
host. Add `SetEnv AWS_PROFILE=…` or `--profile …` to make it visible.

Check what it sees with:

```bash
./ssm-instances.sh hosts     # one host<TAB>instance<TAB>profile row per SSM host
```

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
$env:SSM_AWS_BIN = "$HOME\awscli\Amazon\AWSCLIV2\aws.exe"   # if aws is not on PATH
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

### Arrow-key selection needs fzf

The picker has two modes, chosen by whether `fzf` is on `PATH`: with it you get a
filterable list you navigate with the arrow keys, without it a numbered menu you
type a number into. Both select the same hosts — only the interaction differs.

Git for Windows does not bundle `fzf`, so the numbered menu is what you get out of
the box. Installing it needs no admin rights: take `fzf-*-windows_amd64.zip` from
the [releases page](https://github.com/junegunn/fzf/releases) and drop the binary
in `~/bin`, which Git Bash already has on `PATH`.

```bash
mkdir -p ~/bin && unzip -j ~/Downloads/fzf-*-windows_amd64.zip fzf.exe -d ~/bin
fzf --version
```

Open a new Git Bash session and the script switches modes on its own. `winget
install fzf` works too, where winget is available to you.

This applies to the bash script only. `ssm-instances.ps1` has no `fzf` support at
all and always uses the numbered menu.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No SSM hosts found in …` | the block has no `i-*` HostName, or names no profile. See [what the script reads](#what-ssm-instances-reads-from-these), and check with `./ssm-instances.sh hosts`. |
| `aws CLI not found on PATH` | hand-installed somewhere else — set `SSM_AWS_BIN`, or [put it on PATH](#putting-a-hand-installed-tool-on-path) |
| picker asks for a number instead of arrow keys | `fzf` is not on `PATH` — see [arrow-key selection](#arrow-key-selection-needs-fzf) |
| `SessionManagerPlugin is not found` | plugin not installed, or not on `PATH`. Reopen the terminal after installing — `PATH` changes need a fresh process. |
| `aws : The term 'aws' is not recognized` | AWS CLI not on `PATH`; reopen the terminal after install. |
| `.ps1 cannot be loaded because running scripts is disabled` | see the execution-policy note above |
| `Connection closed by UNKNOWN port 65535` | expired token (no shell fallback in the plain ProxyCommand — run `aws sso login`), or the instance is not connected |
| `Host key verification failed` | first connect to a new instance id; `ssh -o StrictHostKeyChecking=accept-new <host>` once |
| ssh works in terminal, fails in VS Code | unlike macOS this is usually **not** `PATH`. Check the editor was fully restarted, and that it is not using a bundled ssh — set `remote.SSH.path` to `C:\Windows\System32\OpenSSH\ssh.exe`. |
