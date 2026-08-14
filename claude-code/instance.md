---
description: Start or stop an SSM instance, picked from a list
allowed-tools: Bash(*/ssm-instances.sh:*), AskUserQuestion
---

Manage the EC2 instances behind the SSM hosts in `~/.ssh/config`, using
`ssm-instances.sh` from this repo.

Arguments given: `$ARGUMENTS` (may be empty; may name a host and/or `stop`).

Let SCRIPT be the path to `ssm-instances.sh` (adjust the line below to wherever
you cloned it):

    SCRIPT=~/git/ssm-ssh-tools/ssm-instances.sh

Do this:

1. Run `$SCRIPT list` to get each host's EC2 and SSM state, and show that table
   to the user. It takes a few seconds — the lookups run concurrently.

2. Decide the target:
   - If `$ARGUMENTS` names a host unambiguously, use it.
   - Otherwise use AskUserQuestion to let the user pick. Order the options by
     what is actually useful: for `start`, stopped instances first; for `stop`,
     running ones first. Put each option's current state in its description.
     AskUserQuestion allows at most 4 options, so when there are more hosts,
     offer the 4 most relevant and say in the question text that any other host
     can be named directly, e.g. `/instance my-other-host`.

3. Action is `start` unless `$ARGUMENTS` contains `stop`. For `stop`, confirm
   before proceeding — stopping disconnects anyone working on that box. Skip the
   confirmation only when `$ARGUMENTS` already named both the host and `stop`.

4. Run `$SCRIPT <action> <host>`. Pass a generous timeout (300000 ms): a cold
   start plus SSM registration takes a few minutes. Do not run the script with no
   host argument — that opens its interactive picker, which cannot be driven from
   here and will fail on the no-tty guard.

5. Report the outcome plainly, including the instance's hostname on success.
   Specific exit codes worth translating:
   - `3` — credentials expired. Tell the user to run
     `! aws sso login --profile <profile>` in this session, then retry.
   - `4` — the instance id in `~/.ssh/config` points at nothing; its HostName
     needs updating.
   - `7` — it started but SSM never registered, so the agent may be broken on
     that instance.

   If the script reports SSM is Online but ssh still failed, say so rather than
   claiming success — the instance is up but not yet reachable.
