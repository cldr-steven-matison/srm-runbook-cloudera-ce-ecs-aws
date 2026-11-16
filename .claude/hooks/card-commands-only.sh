#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash. The agent may run only a command card.yml names, exactly as
# written, a resume (ecs-run.sh with playbook names) or ecs-wait.sh with a timeout. Anything else is
# refused before it runs. A command typed by the user with ! does not pass through here.
cmd=$(jq -r '.tool_input.command // ""')
root="$(cd "$(dirname "$0")/../.." && pwd)"
sed -nE 's/^ +(run|watch): +//p' "$root/card.yml" | grep -qxF -- "$cmd" && exit 0
books='infrastructure|services|cms|ozone-cluster|ecs-cluster|cai-workbench|pause|resume'
[[ $cmd =~ ^bash\ scripts/ecs-run\.sh(\ --check)?(\ ($books))+$ ]] && exit 0
[[ $cmd =~ ^bash\ scripts/ecs-wait\.sh\ [0-9]+$ ]] && exit 0
echo "Refused: only the commands in card.yml run here. Run the current step's command exactly as written, or stop and report to the user." >&2
exit 2
