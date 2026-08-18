#!/bin/bash
#
# ssm-instances.sh -- start/stop the EC2 instances behind your SSM ssh hosts.
#
# Reads host / instance-id / AWS profile straight out of ~/.ssh/config, so there
# is no second list to keep in sync. Works with ssh host blocks of this shape:
#
#   Host myproject-dev
#     HostName i-0123456789abcdef0
#     ProxyCommand sh -c "... export AWS_PROFILE=my-profile; ... aws ssm start-session ..."
#
# ...and with the Windows spelling of the same thing:
#
#   Host myproject-dev
#     HostName "i-0123456789abcdef0"
#     ProxyCommand powershell.exe "aws --profile my-profile ssm start-session ..."
#
# Usage:
#   ssm-instances.sh                 # pick a host, flip its state (start/stop)
#   ssm-instances.sh start           # picker, start only
#   ssm-instances.sh stop            # picker, stop only
#   ssm-instances.sh list            # table of EC2 state + SSM status
#   ssm-instances.sh start <host>
#   ssm-instances.sh stop  <host>
#   ssm-instances.sh hosts           # machine-readable host<TAB>instance<TAB>profile
#
# Configuration (environment variables):
#   SSM_REGION        AWS region                    (default: from aws config, else us-east-1)
#   SSM_HOST_PREFIX   ssh host name prefix to match (default: matches any host with an i-* HostName)
#   SSM_SSH_CONFIG    path to ssh config            (default: ~/.ssh/config)
#   SSM_AWS_BIN       path to the aws binary        (default: whatever is on PATH)
#
# Exit codes: 2 unknown host, 3 credentials, 4 instance missing, 5 API call failed,
#             6 timed out waiting for state, 7 SSM never registered.

set -uo pipefail

SSH_CONFIG="${SSM_SSH_CONFIG:-$HOME/.ssh/config}"
HOST_PREFIX="${SSM_HOST_PREFIX:-}"
export AWS_PAGER=''

# A hand-installed AWS CLI -- the usual outcome where policy forbids writing to
# Program Files -- often never lands on PATH. SSM_AWS_BIN points straight at the
# binary so the script works without one.
if [ -n "${SSM_AWS_BIN:-}" ]; then
  AWS="$SSM_AWS_BIN"
else
  AWS=$(command -v aws) || {
    echo "aws CLI not found on PATH." >&2
    echo "If it is installed elsewhere, point at it directly:" >&2
    echo "  SSM_AWS_BIN=/path/to/aws $0 ${1:-list}" >&2
    exit 1
  }
fi

# Run it rather than testing the file: under Git Bash the real file is aws.exe,
# so an -x test on the extensionless path is not reliable.
"$AWS" --version >/dev/null 2>&1 || {
  echo "Cannot run the aws CLI at: $AWS" >&2
  exit 1
}

if ! command -v session-manager-plugin >/dev/null 2>&1; then
  echo "Warning: session-manager-plugin not found on PATH; ssh over SSM will fail." >&2
  echo "  (list/start/stop still work -- only the ssh connection itself needs it.)" >&2
  echo "  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
fi

# Region: explicit override, else whatever the aws CLI is configured with.
REGION="${SSM_REGION:-$("$AWS" configure get region 2>/dev/null)}"
REGION="${REGION:-us-east-1}"

[ -f "$SSH_CONFIG" ] || { echo "ssh config not found: $SSH_CONFIG" >&2; exit 1; }

# Turn ssh config blocks into "host<TAB>instance<TAB>profile" rows. A block only
# counts when it has BOTH an i-* HostName and a profile somewhere in the block,
# which is what distinguishes an SSM host from an ordinary one.
#
# Both fields are written several ways in the wild, so accept all of them:
#   HostName i-0123...            HostName "i-0123..."      (Windows configs quote)
#   export AWS_PROFILE=p          SetEnv AWS_PROFILE=p      ($env:AWS_PROFILE='p')
#   aws --profile p ...           aws --profile=p ...       (the Windows/PowerShell form)
# Rows are emitted at the end of a block rather than on the profile line, so the
# two can appear in either order.
parse_hosts() {
  awk -v prefix="$HOST_PREFIX" '
    function unquote(v) { gsub(/^["\047]+|["\047]+$/, "", v); return v }
    function emit() {
      if (host != "" && inst != "" && prof != "") print host "\t" inst "\t" prof
      host = ""; inst = ""; prof = ""
    }
    { sub(/\r$/, "") }                                   # configs saved on Windows are CRLF
    /^[[:space:]]*[Hh]ost[[:space:]]/ {
      emit()
      for (i = 2; i <= NF; i++) {
        if ($i ~ /[*?]/) continue                        # skip wildcard blocks
        cand = unquote($i)
        if (prefix == "" || index(cand, prefix) == 1) { host = cand; break }
      }
      next
    }
    host == "" { next }
    /^[[:space:]]*[Hh]ost[Nn]ame[[:space:]]/ {
      cand = unquote($2)
      if (cand ~ /^i-[0-9a-fA-F]+$/) inst = cand
      next
    }
    # First profile mentioned in the block wins; a ProxyCommand naming it three
    # times (sts / sso login / start-session) names the same one each time.
    prof == "" {
      if (match($0, /AWS_PROFILE[[:space:]]*=[[:space:]]*["\047]?[A-Za-z0-9._+@-]+/)) {
        v = substr($0, RSTART, RLENGTH)
        sub(/^AWS_PROFILE[[:space:]]*=[[:space:]]*["\047]?/, "", v)
        prof = v
      } else if (match($0, /--profile[[:space:]=]+["\047]?[A-Za-z0-9._+@-]+/)) {
        v = substr($0, RSTART, RLENGTH)
        sub(/^--profile[[:space:]=]+["\047]?/, "", v)
        prof = v
      }
    }
    END { emit() }
  ' "$SSH_CONFIG"
}

resolve() {
  local want="$1" row
  row=$(parse_hosts | awk -F'\t' -v h="$want" '$1 == h { print; exit }')
  if [ -z "$row" ]; then
    echo "Unknown host: $want" >&2
    echo "Known hosts:" >&2
    parse_hosts | cut -f1 | sed 's/^/  /' >&2
    exit 2
  fi
  HOST=$(echo "$row" | cut -f1)
  INSTANCE=$(echo "$row" | cut -f2)
  PROFILE=$(echo "$row" | cut -f3)
}

have_creds() {
  "$AWS" sts get-caller-identity --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1
}

# Mirrors the `|| aws sso login` fallback in the ProxyCommand: refresh the token
# when it has lapsed. That opens a browser, so only try it with a terminal
# attached -- otherwise it would block forever on input nobody can give.
check_creds() {
  have_creds && return 0

  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "Credentials invalid/expired for profile: $PROFILE" >&2
    echo "No terminal available for an interactive login. Run this, then retry:" >&2
    echo "  aws sso login --profile $PROFILE" >&2
    exit 3
  fi

  echo "Credentials expired for $PROFILE -- attempting sso login..." >&2
  if ! "$AWS" sso login --profile "$PROFILE" >&2; then
    echo "sso login failed for $PROFILE." >&2
    echo "If this profile does not use SSO, refresh its credentials manually." >&2
    exit 3
  fi

  # Verify the refresh actually worked instead of trusting the exit status.
  if ! have_creds; then
    echo "Still no valid credentials for $PROFILE after login." >&2
    exit 3
  fi
  echo "Logged in to $PROFILE." >&2
}

ec2_state() {
  "$AWS" ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
    --instance-ids "$INSTANCE" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null
}

ssm_status() {
  local s
  s=$("$AWS" ssm describe-instance-information --profile "$PROFILE" --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
  if [ -z "$s" ] || [ "$s" = "None" ]; then echo "-"; else echo "$s"; fi
}

# Every state lookup for ONE profile, as "instance<TAB>ec2<TAB>ssm" lines.
#
# Both APIs accept many instance ids per call, so this costs 3 aws invocations
# per profile instead of 1 + 2 per host. That matters far more than it looks:
# nothing here is network-bound, it is aws CLI start-up, which is ~0.3s on macOS
# but frequently 1-2s under Git Bash on Windows.
#
# Run as a background job by cmd_list, so it must not depend on any shared state
# beyond its arguments.
profile_states() {
  local profile="$1" idfile="$2" out="$3"
  local ids csv ec2f ssmf okf

  ids=$(tr '\n' ' ' < "$idfile")
  csv=$(paste -sd, - < "$idfile")
  ec2f="$idfile.ec2"; ssmf="$idfile.ssm"; okf="$idfile.creds"

  # All three calls start together. Start-up, not the API, is the cost here, so
  # overlapping them makes a profile take one aws start-up instead of three --
  # which is the entire runtime when each host has its own profile and there is
  # nothing left to batch.
  ( "$AWS" sts get-caller-identity --profile "$profile" --region "$REGION" >/dev/null 2>&1 \
      && echo ok > "$okf" ) &

  # Word-splitting $ids into separate --instance-ids arguments is the point here.
  # shellcheck disable=SC2086
  "$AWS" ec2 describe-instances --profile "$profile" --region "$REGION" \
    --instance-ids $ids \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
    --output text > "$ec2f" 2>/dev/null &

  # describe-instance-information simply omits ids it does not know, so it needs
  # no fallback -- a missing row means "not registered", which reads as "-".
  "$AWS" ssm describe-instance-information --profile "$profile" --region "$REGION" \
    --filters "Key=InstanceIds,Values=$csv" \
    --query 'InstanceInformationList[].[InstanceId,PingStatus]' \
    --output text > "$ssmf" 2>/dev/null &
  wait

  # Credentials decide whether the other two results mean anything, so this is
  # checked after rather than gating them.
  if [ ! -s "$okf" ]; then
    awk '{ print $1 "\tno-creds\t-" }' "$idfile" > "$out"
    return
  fi

  # One unknown id fails the WHOLE describe-instances call, which would blank out
  # every row on this profile. Fall back to per-host calls just for this profile,
  # so a stale HostName costs speed rather than the whole table.
  if [ ! -s "$ec2f" ]; then
    local i st
    while read -r i; do
      st=$("$AWS" ec2 describe-instances --profile "$profile" --region "$REGION" \
             --instance-ids "$i" \
             --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null)
      printf '%s\t%s\n' "$i" "$st"
    done < "$idfile" > "$ec2f"
  fi

  # Drive the join from idfile so every host gets a row even when both APIs
  # omitted it.
  awk -F'\t' -v e="$ec2f" -v s="$ssmf" '
    function val(v) { return (v == "" || v == "None") ? "" : v }
    FILENAME == e { ec2[$1] = val($2); next }
    FILENAME == s { ssm[$1] = val($2); next }
    { print $1 "\t" (ec2[$1] == "" ? "missing" : ec2[$1]) \
               "\t" (ssm[$1] == "" ? "-" : ssm[$1]) }
  ' "$ec2f" "$ssmf" "$idfile" > "$out"
}

cmd_list() {
  local rows; rows=$(parse_hosts)
  [ -z "$rows" ] && {
    echo "No SSM hosts found in $SSH_CONFIG." >&2
    echo "Expected blocks with an i-* HostName and a profile -- either AWS_PROFILE=" >&2
    echo "in the block (export/SetEnv/\$env:) or --profile in the ProxyCommand." >&2
    exit 1
  }

  local tmp; tmp=$(mktemp -d)

  # One background job per profile, not per host, each fetching that profile's
  # whole slice of the table.
  local n=0 prof
  while read -r prof; do
    n=$((n + 1))
    echo "$rows" | awk -F'\t' -v p="$prof" '$3 == p { print $2 }' > "$tmp/ids.$n"
    profile_states "$prof" "$tmp/ids.$n" "$tmp/state.$n" &
  done < <(echo "$rows" | cut -f3 | sort -u)
  wait

  cat "$tmp"/state.* > "$tmp/all" 2>/dev/null
  touch "$tmp/all"

  # Print in ssh-config order by walking the parsed rows, not the fetched state.
  printf '%-34s %-21s %-12s %s\n' HOST INSTANCE EC2 SSM
  echo "$rows" | awk -F'\t' -v all="$tmp/all" '
    BEGIN { while ((getline line < all) > 0) {
              split(line, f, "\t"); ec2[f[1]] = f[2]; ssm[f[1]] = f[3] } }
    { printf "%-34s %-21s %-12s %s\n", $1, $2,
             (ec2[$2] == "" ? "?" : ec2[$2]), (ssm[$2] == "" ? "-" : ssm[$2]) }
  '
  rm -rf "$tmp"
}

cmd_start() {
  resolve "$1"; check_creds
  local state; state=$(ec2_state)
  echo "$HOST -> $INSTANCE ($PROFILE), state: $state"

  case "$state" in
    running)
      # Already up: if SSM is live too there is nothing to wait for, so say it is
      # ready and stop rather than re-running the whole boot-wait sequence.
      if [ "$(ssm_status)" = "Online" ]; then
        echo "Already running and Online. Connect with: ssh $HOST"
        return 0
      fi
      echo "Already running, but SSM is not registered yet."
      ;;
    ""|None) echo "Instance does not exist. Check the HostName in $SSH_CONFIG." >&2; exit 4 ;;
    *)
      "$AWS" ec2 start-instances --profile "$PROFILE" --region "$REGION" \
        --instance-ids "$INSTANCE" --output text >/dev/null || exit 5
      echo "Starting; waiting for running state..."
      "$AWS" ec2 wait instance-running --profile "$PROFILE" --region "$REGION" \
        --instance-ids "$INSTANCE" || { echo "Timed out waiting for running." >&2; exit 6; }
      echo "Running."
      ;;
  esac

  # The SSM agent checks in well after the instance reports running; skipping
  # this wait means an immediate ssh fails with TargetNotConnected.
  echo "Waiting for SSM agent to register (up to 3 min)..."
  local registered=""
  for _ in $(seq 1 36); do
    if [ "$(ssm_status)" = "Online" ]; then registered=yes; break; fi
    sleep 5
  done
  [ -z "$registered" ] && { echo "SSM did not register in time. Re-check with: $0 list" >&2; exit 7; }
  echo "SSM: Online"

  # Online means "registered with the control plane", which happens slightly
  # before the agent can actually accept sessions -- so retry rather than
  # declaring failure on the first TargetNotConnected.
  # accept-new lets a brand-new instance through while still refusing a CHANGED
  # key on a host already in known_hosts.
  echo "Verifying ssh..."
  local out
  for try in 1 2 3 4 5; do
    out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
              -o ConnectTimeout=30 "$HOST" 'hostname' 2>&1)
    if echo "$out" | grep -q '^ip-'; then
      echo "CONNECTED: ssh $HOST  ($(echo "$out" | grep '^ip-' | tail -1))"
      return 0
    fi
    [ "$try" -lt 5 ] && { echo "  not ready yet, retrying..." >&2; sleep 15; }
  done
  echo "SSM is online but ssh did not succeed; try: ssh $HOST"
  echo "$out" | grep -viE 'post-quantum|store now|upgraded|^\*\*' | tail -2
}

cmd_stop() {
  resolve "$1"; check_creds
  local state; state=$(ec2_state)
  echo "$HOST -> $INSTANCE ($PROFILE), state: $state"
  [ "$state" = "stopped" ] && { echo "Already stopped."; return 0; }
  [ -z "$state" ] || [ "$state" = "None" ] && { echo "Instance does not exist." >&2; exit 4; }
  "$AWS" ec2 stop-instances --profile "$PROFILE" --region "$REGION" \
    --instance-ids "$INSTANCE" --output text >/dev/null || exit 5
  echo "Stopping; waiting..."
  "$AWS" ec2 wait instance-stopped --profile "$PROFILE" --region "$REGION" \
    --instance-ids "$INSTANCE" && echo "Stopped."
}

cmd_pick() {
  local requested="${1:-toggle}" action table host
  case "$requested" in toggle|start|stop) ;; *) echo "usage: $0 pick [toggle|start|stop]" >&2; exit 1 ;; esac

  # Both pickers need a real terminal. Without this guard fzf blocks forever when
  # stdin is a pipe or /dev/null, which is worse than failing outright.
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "" >&2
    echo "No terminal for interactive selection. Name a host directly:" >&2
    # `toggle` is picker-only, so suggest a real subcommand.
    case "$requested" in
      toggle) echo "  $0 start <host>   or   $0 stop <host>" >&2 ;;
      *)      echo "  $0 $requested <host>" >&2 ;;
    esac
    exit 1
  fi

  # Loop so several hosts can be handled in one sitting. The table is re-fetched
  # each pass because the host just acted on has a new state.
  while :; do
  action="$requested"
  echo "Loading instance states..." >&2
  table=$(cmd_list) || exit $?
  echo "$table" >&2

  # A row of no-creds looks like the instances are unreachable; they aren't.
  if echo "$table" | grep -q 'no-creds'; then
    echo "" >&2
    echo "Note: no-creds rows have expired credentials, so their state is unknown" >&2
    echo "here. Picking one will log in first." >&2
  fi

  if command -v fzf >/dev/null 2>&1; then
    host=$(echo "$table" | tail -n +2 | \
      fzf --height=40% --reverse --prompt="$action which host? " \
          --header="$(echo "$table" | head -1)" | awk '{print $1}')
  else
    local hosts n
    hosts=$(echo "$table" | tail -n +2 | awk '{print $1}')
    echo "" >&2
    echo "$hosts" | nl -w2 -s') ' >&2
    printf "%s which number (Enter to quit)? " "$action" >&2
    read -r n
    # Only a plain number selects; anything else (including empty) means quit.
    # Without this an empty $n makes sed print every line, so $host is non-empty.
    case "$n" in
      ''|*[!0-9]*) host="" ;;
      *) host=$(echo "$hosts" | sed -n "${n}p") ;;
    esac
  fi

  # Empty selection (Esc in fzf, or a blank line) is how you leave the loop.
  [ -z "$host" ] && { echo "Done." >&2; return 0; }
  echo "" >&2

  # Toggle uses the state already fetched for the table, so deciding the action
  # costs no extra API call.
  if [ "$action" = "toggle" ]; then
    local sel_state
    sel_state=$(echo "$table" | awk -v h="$host" '$1 == h { print $3; exit }')
    case "$sel_state" in
      running)
        # Stopping disconnects anyone working on the box, so make it deliberate.
        printf "Stop %s? [y/N] " "$host" >&2
        local reply; read -r reply
        case "$reply" in
          [yY]|[yY][eE][sS]) action=stop ;;
          # Declining returns to the list rather than quitting.
          *) echo "Skipped." >&2; echo "" >&2; continue ;;
        esac
        ;;
      stopped)  action=start ;;
      no-creds) action=start ;;   # log in first, then act on the real state
      *)
        echo "Cannot toggle $host (state: ${sel_state:-unknown})." >&2
        echo "Use: $0 start $host   or   $0 stop $host" >&2
        echo "" >&2
        continue
        ;;
    esac
  fi

  # Keep going even if the action failed, so one bad host does not end the
  # session; the refreshed table next pass shows what actually happened.
  cmd_"$action" "$host" || echo "($action failed for $host)" >&2

  echo "" >&2
  printf -- "-- press Enter for the list, or q to quit -- " >&2
  local again; read -r again
  case "$again" in [qQ]*) echo "Done." >&2; return 0 ;; esac
  echo "" >&2
  done
}

case "${1:-pick}" in
  # Bare invocation: pick a host and flip its state (stopped -> start,
  # running -> stop after confirming).
  pick)  cmd_pick "${2:-toggle}" ;;
  list)  cmd_list ;;
  hosts) parse_hosts ;;
  # A bare `start`/`stop` means "start something" -- fall through to the picker
  # rather than making the user retype the command with a host name.
  start) [ $# -ge 2 ] && cmd_start "$2" || cmd_pick start ;;
  stop)  [ $# -ge 2 ] && cmd_stop  "$2" || cmd_pick stop  ;;
  -h|--help|help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)     echo "usage: $0 {pick [toggle|start|stop]|list|start <host>|stop <host>|hosts}" >&2; exit 1 ;;
esac
