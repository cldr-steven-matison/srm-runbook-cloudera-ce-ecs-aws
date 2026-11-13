#!/usr/bin/env bash
# One poll of a detached run. Blocks until the run in tmux ends, its artifact status changes, or MAX
# seconds pass (default 540, under the 10-minute tool limit), then prints ecs-status.sh. Read-only.
#   bash scripts/ecs-wait.sh        # wait up to 9 minutes
#   bash scripts/ecs-wait.sh 60     # wait up to 60 seconds
set -uo pipefail
. "$(dirname "$0")/env.sh"
MAX=${1:-540}
snap() { local a; a=$(ls -td "$ECS_REPO"/runs/artifacts/*/ 2>/dev/null | head -1); echo "$a $(cat "${a}status" 2>/dev/null)"; }
s0=$(snap); t0=$(date +%s)
while tmux has-session -t "$SESSION" 2>/dev/null && [ "$(snap)" = "$s0" ] && [ $(( $(date +%s) - t0 )) -lt "$MAX" ]; do
  sleep 15
done
echo "waited $(( $(date +%s) - t0 ))s"
exec bash "$HERE/ecs-status.sh"
