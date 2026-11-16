#!/usr/bin/env bash
# Claude Code Stop hook. While a run is live in tmux, the agent may not end its turn: an agent that
# ends its turn leaves the run unwatched until someone types, and two runs sat idle for an hour that way.
. "$(dirname "$0")/../../scripts/env.sh"
tmux has-session -t "$SESSION" 2>/dev/null || exit 0
echo "A run is in progress in tmux session $SESSION. Do not end your turn. Run: bash scripts/ecs-wait.sh" >&2
exit 2
