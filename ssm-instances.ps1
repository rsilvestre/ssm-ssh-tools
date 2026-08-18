<#
.SYNOPSIS
  Start/stop the EC2 instances behind your SSM ssh hosts (PowerShell port).

.DESCRIPTION
  Reads host / instance-id / AWS profile straight out of your ssh config, so
  there is no second list to keep in sync. Recognises host blocks of this shape:

    Host myproject-dev
      HostName i-0123456789abcdef0
      ProxyCommand ... export AWS_PROFILE=my-profile; ... aws ssm start-session ...

  ...and the Windows spelling of the same thing:

    Host myproject-dev
      HostName "i-0123456789abcdef0"
      ProxyCommand powershell.exe "aws --profile my-profile ssm start-session ..."

  Behavioural twin of ssm-instances.sh, including its exit codes, but slower:
  state is fetched per host here, where the bash version batches it per profile.
  Requires PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+ (any platform).

.PARAMETER Action
  toggle (default), start, stop, list, or hosts.

.PARAMETER TargetHost
  Host name from the ssh config. Omit it to get the interactive picker.

.EXAMPLE
  .\ssm-instances.ps1
  Pick a host and flip its state.

.EXAMPLE
  .\ssm-instances.ps1 start myproject-dev
  Start that host, wait for SSM, verify ssh.

.NOTES
  Configuration via environment variables:
    SSM_REGION       AWS region       (default: aws configure get region, else us-east-1)
    SSM_HOST_PREFIX  host prefix filter (default: any host with an i-* HostName)
    SSM_SSH_CONFIG   ssh config path  (default: ~/.ssh/config)
    SSM_AWS_BIN      path to aws.exe  (default: whatever is on PATH)

  Exit codes: 2 unknown host, 3 credentials, 4 instance missing,
              5 API call failed, 6 timed out waiting, 7 SSM never registered.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('toggle', 'start', 'stop', 'list', 'hosts')]
  [string]$Action = 'toggle',

  [Parameter(Position = 1)]
  [string]$TargetHost
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Keep the AWS CLI from paging into an interactive viewer.
$env:AWS_PAGER = ''

$SshConfig = if ($env:SSM_SSH_CONFIG) { $env:SSM_SSH_CONFIG }
             else { Join-Path $HOME '.ssh/config' }
$HostPrefix = if ($env:SSM_HOST_PREFIX) { $env:SSM_HOST_PREFIX } else { '' }

# A hand-installed AWS CLI -- the usual outcome where policy forbids writing to
# Program Files -- often never lands on PATH. SSM_AWS_BIN points straight at the
# binary so the script works without one.
if ($env:SSM_AWS_BIN) {
  $Aws = $env:SSM_AWS_BIN
} else {
  $AwsCmd = Get-Command aws -ErrorAction SilentlyContinue
  if (-not $AwsCmd) {
    Write-Host 'aws CLI not found on PATH.' -ForegroundColor Red
    Write-Host 'If it is installed elsewhere, point at it directly:'
    Write-Host '  $env:SSM_AWS_BIN = "C:\path\to\aws.exe"'
    exit 1
  }
  $Aws = $AwsCmd.Source
}

# Run it rather than testing the path, so a wrong SSM_AWS_BIN fails here with a
# clear message instead of at the first API call.
# ErrorActionPreference is Stop, so a bad path throws rather than setting an
# exit code -- catch it so the message below is what the user actually sees.
$awsOk = $false
try { & $Aws --version *> $null; $awsOk = ($LASTEXITCODE -eq 0) } catch { $awsOk = $false }
if (-not $awsOk) {
  Write-Host "Cannot run the aws CLI at: $Aws" -ForegroundColor Red
  exit 1
}

if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) {
  Write-Warning 'session-manager-plugin not found on PATH; ssh over SSM will fail.'
  Write-Warning '  (list/start/stop still work -- only the ssh connection itself needs it.)'
  Write-Warning '  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html'
}

$Region = if ($env:SSM_REGION) { $env:SSM_REGION }
          else { (& $Aws configure get region 2>$null) }
if (-not $Region) { $Region = 'us-east-1' }

if (-not (Test-Path -LiteralPath $SshConfig)) {
  Write-Error "ssh config not found: $SshConfig"
  exit 1
}

# --- ssh config parsing -----------------------------------------------------
# A block counts as an SSM host only when it has BOTH an i-* HostName and a
# profile somewhere in the block; that is what separates these from ordinary
# ssh hosts.
#
# Both fields are written several ways in the wild, so accept all of them:
#   HostName i-0123...      HostName "i-0123..."   (Windows configs quote)
#   AWS_PROFILE=p           SetEnv AWS_PROFILE=p   ($env:AWS_PROFILE='p')
#   aws --profile p ...     aws --profile=p ...    (the Windows/PowerShell form)
# Rows are emitted at the end of a block rather than on the profile line, so the
# two can appear in either order. Kept in step with parse_hosts() in the bash
# version -- both must select the same hosts from the same config.
function Get-SsmHosts {
  $rows = [System.Collections.Generic.List[object]]::new()
  $hostName = ''; $instance = ''; $profileName = ''

  # Values are passed in rather than captured, so this depends on nothing but
  # its arguments and $rows.
  $emit = {
    param($h, $i, $p)
    if ($h -and $i -and $p) {
      $rows.Add([pscustomobject]@{ HostName = $h; Instance = $i; Profile = $p })
    }
  }

  foreach ($line in Get-Content -LiteralPath $SshConfig) {
    $text = $line -replace '\r$', ''      # configs saved on Windows are CRLF

    if ($text -match '^\s*[Hh]ost\s+(.+)$') {
      & $emit $hostName $instance $profileName
      $hostName = ''; $instance = ''; $profileName = ''
      foreach ($candidate in ($Matches[1] -split '\s+')) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($candidate -match '[*?]') { continue }          # skip wildcard blocks
        $candidate = $candidate.Trim('"', "'")
        if ($HostPrefix -and -not $candidate.StartsWith($HostPrefix)) { continue }
        $hostName = $candidate
        break
      }
      continue
    }
    if (-not $hostName) { continue }

    if ($text -match '^\s*[Hh]ost[Nn]ame\s+["'']?(i-[0-9a-fA-F]+)') {
      $instance = $Matches[1]
      continue
    }

    # First profile mentioned in the block wins; a ProxyCommand naming it three
    # times (sts / sso login / start-session) names the same one each time.
    if (-not $profileName) {
      if ($text -match 'AWS_PROFILE\s*=\s*["'']?([A-Za-z0-9._+@-]+)') {
        $profileName = $Matches[1]
      } elseif ($text -match '--profile[\s=]+["'']?([A-Za-z0-9._+@-]+)') {
        $profileName = $Matches[1]
      }
    }
  }
  & $emit $hostName $instance $profileName
  return $rows
}

function Resolve-SsmHost {
  param([string]$Name)
  $all = Get-SsmHosts
  $row = $all | Where-Object { $_.HostName -eq $Name } | Select-Object -First 1
  if (-not $row) {
    Write-Host "Unknown host: $Name" -ForegroundColor Red
    Write-Host 'Known hosts:'
    $all | ForEach-Object { Write-Host "  $($_.HostName)" }
    exit 2
  }
  return $row
}

# --- AWS helpers ------------------------------------------------------------

function Test-Credentials {
  param([string]$ProfileName)
  & $Aws sts get-caller-identity --profile $ProfileName --region $Region *> $null
  return ($LASTEXITCODE -eq 0)
}

# Same fallback as the ProxyCommand: try the call, and refresh the token when it
# has lapsed. sso login opens a browser, so only attempt it interactively --
# otherwise it would block forever on input nobody can supply.
function Assert-Credentials {
  param([string]$ProfileName)
  if (Test-Credentials $ProfileName) { return }

  if (-not [Environment]::UserInteractive) {
    Write-Host "Credentials invalid/expired for profile: $ProfileName"
    Write-Host 'Not an interactive session. Run this, then retry:'
    Write-Host "  aws sso login --profile $ProfileName"
    exit 3
  }

  Write-Host "Credentials expired for $ProfileName -- attempting sso login..."
  & $Aws sso login --profile $ProfileName
  if ($LASTEXITCODE -ne 0) {
    Write-Host "sso login failed for $ProfileName."
    Write-Host 'If this profile does not use SSO, refresh its credentials manually.'
    exit 3
  }
  # Verify the refresh actually produced usable credentials rather than
  # trusting the exit status.
  if (-not (Test-Credentials $ProfileName)) {
    Write-Host "Still no valid credentials for $ProfileName after login."
    exit 3
  }
  Write-Host "Logged in to $ProfileName."
}

function Get-Ec2State {
  param([string]$ProfileName, [string]$Instance)
  $s = & $Aws ec2 describe-instances --profile $ProfileName --region $Region `
        --instance-ids $Instance `
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $s -or $s -eq 'None') { return '' }
  return $s.Trim()
}

function Get-SsmStatus {
  param([string]$ProfileName, [string]$Instance)
  $s = & $Aws ssm describe-instance-information --profile $ProfileName --region $Region `
        --filters "Key=InstanceIds,Values=$Instance" `
        --query 'InstanceInformationList[0].PingStatus' --output text 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $s -or $s.Trim() -eq 'None') { return '-' }
  return $s.Trim()
}

# --- list -------------------------------------------------------------------

# Each profile is checked once (not once per host) and every lookup runs
# concurrently; serially this dominated the runtime.
function Get-StateTable {
  $rows = Get-SsmHosts
  if ($rows.Count -eq 0) {
    Write-Host "No SSM hosts found in $SshConfig"
    Write-Host 'Expected blocks with an i-* HostName and AWS_PROFILE= in the ProxyCommand.'
    exit 1
  }

  $profiles = $rows | Select-Object -ExpandProperty Profile -Unique
  $credOk = @{}

  $credJobs = foreach ($p in $profiles) {
    Start-Job -ScriptBlock {
      param($aws, $prof, $region)
      & $aws sts get-caller-identity --profile $prof --region $region *> $null
      [pscustomobject]@{ Profile = $prof; Ok = ($LASTEXITCODE -eq 0) }
    } -ArgumentList $Aws, $p, $Region
  }
  foreach ($r in (Receive-Job -Job $credJobs -Wait -AutoRemoveJob)) {
    $credOk[$r.Profile] = $r.Ok
  }

  $stateJobs = foreach ($row in $rows) {
    if (-not $credOk[$row.Profile]) { continue }
    Start-Job -ScriptBlock {
      param($aws, $prof, $region, $instance, $hostName)
      $ec2 = & $aws ec2 describe-instances --profile $prof --region $region `
               --instance-ids $instance `
               --query 'Reservations[0].Instances[0].State.Name' --output text 2>$null
      if (-not $ec2 -or $ec2 -eq 'None') { $ec2 = 'missing' }
      $ssm = & $aws ssm describe-instance-information --profile $prof --region $region `
               --filters "Key=InstanceIds,Values=$instance" `
               --query 'InstanceInformationList[0].PingStatus' --output text 2>$null
      if (-not $ssm -or $ssm.Trim() -eq 'None') { $ssm = '-' }
      [pscustomobject]@{ HostName = $hostName; Ec2 = $ec2.Trim(); Ssm = $ssm.Trim() }
    } -ArgumentList $Aws, $row.Profile, $Region, $row.Instance, $row.HostName
  }

  $states = @{}
  if ($stateJobs) {
    foreach ($r in (Receive-Job -Job $stateJobs -Wait -AutoRemoveJob)) {
      $states[$r.HostName] = $r
    }
  }

  # Rebuild in ssh-config order rather than job-completion order.
  return $rows | ForEach-Object {
    if ($states.ContainsKey($_.HostName)) {
      [pscustomobject]@{
        HostName = $_.HostName; Instance = $_.Instance; Profile = $_.Profile
        Ec2 = $states[$_.HostName].Ec2; Ssm = $states[$_.HostName].Ssm
      }
    } else {
      [pscustomobject]@{
        HostName = $_.HostName; Instance = $_.Instance; Profile = $_.Profile
        Ec2 = 'no-creds'; Ssm = '-'
      }
    }
  }
}

function Show-StateTable {
  param($Table)
  '{0,-34} {1,-21} {2,-12} {3}' -f 'HOST', 'INSTANCE', 'EC2', 'SSM' | Write-Host
  foreach ($r in $Table) {
    '{0,-34} {1,-21} {2,-12} {3}' -f $r.HostName, $r.Instance, $r.Ec2, $r.Ssm | Write-Host
  }
}

# --- start / stop -----------------------------------------------------------

function Start-SsmHost {
  param([string]$Name)
  $row = Resolve-SsmHost $Name
  Assert-Credentials $row.Profile

  $state = Get-Ec2State $row.Profile $row.Instance
  Write-Host "$($row.HostName) -> $($row.Instance) ($($row.Profile)), state: $state"

  if ($state -eq 'running') {
    # Already up: if SSM is live too there is nothing to wait for.
    if ((Get-SsmStatus $row.Profile $row.Instance) -eq 'Online') {
      Write-Host "Already running and Online. Connect with: ssh $($row.HostName)"
      return
    }
    Write-Host 'Already running, but SSM is not registered yet.'
  }
  elseif (-not $state) {
    Write-Host "Instance does not exist. Check the HostName in $SshConfig"
    exit 4
  }
  else {
    & $Aws ec2 start-instances --profile $row.Profile --region $Region `
      --instance-ids $row.Instance --output text *> $null
    if ($LASTEXITCODE -ne 0) { exit 5 }
    Write-Host 'Starting; waiting for running state...'
    & $Aws ec2 wait instance-running --profile $row.Profile --region $Region `
      --instance-ids $row.Instance
    if ($LASTEXITCODE -ne 0) { Write-Host 'Timed out waiting for running.'; exit 6 }
    Write-Host 'Running.'
  }

  # The SSM agent checks in well after the instance reports running; skipping
  # this wait means an immediate ssh fails with TargetNotConnected.
  Write-Host 'Waiting for SSM agent to register (up to 3 min)...'
  $registered = $false
  foreach ($i in 1..36) {
    if ((Get-SsmStatus $row.Profile $row.Instance) -eq 'Online') { $registered = $true; break }
    Start-Sleep -Seconds 5
  }
  if (-not $registered) {
    Write-Host 'SSM did not register in time. Re-check with: list'
    exit 7
  }
  Write-Host 'SSM: Online'

  # Online means "registered with the control plane", which happens slightly
  # before the agent can accept sessions -- so retry rather than failing on the
  # first TargetNotConnected. accept-new lets a brand-new instance through while
  # still refusing a CHANGED key on a host already in known_hosts.
  Write-Host 'Verifying ssh...'
  $out = ''
  foreach ($try in 1..5) {
    $out = (ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new `
                -o ConnectTimeout=30 $row.HostName 'hostname' 2>&1) -join "`n"
    $match = ($out -split "`n" | Where-Object { $_ -match '^ip-' } | Select-Object -Last 1)
    if ($match) {
      Write-Host "CONNECTED: ssh $($row.HostName)  ($match)"
      return
    }
    if ($try -lt 5) { Write-Host '  not ready yet, retrying...'; Start-Sleep -Seconds 15 }
  }
  Write-Host "SSM is online but ssh did not succeed; try: ssh $($row.HostName)"
  ($out -split "`n" | Where-Object { $_ -notmatch 'post-quantum|store now|upgraded|^\*\*' } |
    Select-Object -Last 2) | ForEach-Object { Write-Host $_ }
}

function Stop-SsmHost {
  param([string]$Name)
  $row = Resolve-SsmHost $Name
  Assert-Credentials $row.Profile

  $state = Get-Ec2State $row.Profile $row.Instance
  Write-Host "$($row.HostName) -> $($row.Instance) ($($row.Profile)), state: $state"
  if ($state -eq 'stopped') { Write-Host 'Already stopped.'; return }
  if (-not $state) { Write-Host 'Instance does not exist.'; exit 4 }

  & $Aws ec2 stop-instances --profile $row.Profile --region $Region `
    --instance-ids $row.Instance --output text *> $null
  if ($LASTEXITCODE -ne 0) { exit 5 }
  Write-Host 'Stopping; waiting...'
  & $Aws ec2 wait instance-stopped --profile $row.Profile --region $Region `
    --instance-ids $row.Instance
  if ($LASTEXITCODE -eq 0) { Write-Host 'Stopped.' }
}

# --- interactive picker -----------------------------------------------------

function Invoke-Picker {
  param([string]$Requested)

  if (-not [Environment]::UserInteractive) {
    Write-Host 'Not an interactive session. Name a host directly:'
    if ($Requested -eq 'toggle') {
      Write-Host '  ssm-instances.ps1 start <host>   or   ssm-instances.ps1 stop <host>'
    } else {
      Write-Host "  ssm-instances.ps1 $Requested <host>"
    }
    exit 1
  }

  # Loop so several hosts can be handled in one sitting. The table is re-fetched
  # each pass because the host just acted on has a new state.
  while ($true) {
    $action = $Requested
    Write-Host 'Loading instance states...'
    $table = Get-StateTable
    Show-StateTable $table

    if ($table | Where-Object { $_.Ec2 -eq 'no-creds' }) {
      Write-Host ''
      Write-Host 'Note: no-creds rows have expired credentials, so their state is unknown'
      Write-Host 'here. Picking one will log in first.'
    }

    Write-Host ''
    for ($i = 0; $i -lt $table.Count; $i++) {
      '{0,2}) {1}' -f ($i + 1), $table[$i].HostName | Write-Host
    }
    $reply = Read-Host "$action which number (Enter to quit)?"

    # Only a plain number selects; anything else (including empty) quits.
    if ($reply -notmatch '^\d+$') { Write-Host 'Done.'; return }
    $idx = [int]$reply
    if ($idx -lt 1 -or $idx -gt $table.Count) { Write-Host 'Done.'; return }
    $chosen = $table[$idx - 1]

    Write-Host ''

    if ($action -eq 'toggle') {
      switch ($chosen.Ec2) {
        'running' {
          # Stopping disconnects anyone working on the box, so make it deliberate.
          $confirm = Read-Host "Stop $($chosen.HostName)? [y/N]"
          if ($confirm -notmatch '^[yY]') {
            Write-Host 'Skipped.'; Write-Host ''
            continue
          }
          $action = 'stop'
        }
        'stopped'  { $action = 'start' }
        'no-creds' { $action = 'start' }   # log in first, then act on real state
        default {
          Write-Host "Cannot toggle $($chosen.HostName) (state: $($chosen.Ec2))."
          Write-Host "Use: start $($chosen.HostName)   or   stop $($chosen.HostName)"
          Write-Host ''
          continue
        }
      }
    }

    # Keep going even if the action failed, so one bad host does not end the
    # session; the refreshed table next pass shows what actually happened.
    try {
      if ($action -eq 'start') { Start-SsmHost $chosen.HostName }
      else { Stop-SsmHost $chosen.HostName }
    } catch {
      Write-Host "($action failed for $($chosen.HostName): $($_.Exception.Message))"
    }

    Write-Host ''
    $again = Read-Host '-- press Enter for the list, or q to quit --'
    if ($again -match '^[qQ]') { Write-Host 'Done.'; return }
    Write-Host ''
  }
}

# --- dispatch ---------------------------------------------------------------

switch ($Action) {
  'hosts' {
    Get-SsmHosts | ForEach-Object { "$($_.HostName)`t$($_.Instance)`t$($_.Profile)" }
  }
  'list' {
    Show-StateTable (Get-StateTable)
  }
  'start' {
    if ($TargetHost) { Start-SsmHost $TargetHost } else { Invoke-Picker 'start' }
  }
  'stop' {
    if ($TargetHost) { Stop-SsmHost $TargetHost } else { Invoke-Picker 'stop' }
  }
  'toggle' {
    if ($TargetHost) {
      # An explicit host with no verb is ambiguous, so decide from current state.
      $row = Resolve-SsmHost $TargetHost
      Assert-Credentials $row.Profile
      if ((Get-Ec2State $row.Profile $row.Instance) -eq 'running') {
        Stop-SsmHost $TargetHost
      } else {
        Start-SsmHost $TargetHost
      }
    } else {
      Invoke-Picker 'toggle'
    }
  }
}
