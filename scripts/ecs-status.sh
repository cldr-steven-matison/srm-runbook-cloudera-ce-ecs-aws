#!/usr/bin/env bash
# Where the current or last run is, from the newest ansible-runner artifact (status, last play, task and
# fatal, PLAY RECAP) and from Cloudera Manager. Read-only.
#   bash scripts/ecs-status.sh
set -uo pipefail
. "$(dirname "$0")/env.sh"
cd "$ECS_REPO" || exit 1
echo "== $(date -u '+%Y-%m-%d %H:%M:%S') UTC"
if tmux has-session -t "$SESSION" 2>/dev/null; then echo "run: IN PROGRESS (tmux $SESSION)"; else echo "run: none in progress"; fi
L=$(ls -t runs/*.log 2>/dev/null | head -1)
[ -n "$L" ] && echo "log: $L  $(grep -aE '^(RUN|TEARDOWN) END' "$L" | tail -1)"
A=$(ls -td runs/artifacts/*/ 2>/dev/null | head -1)
if [ -n "$A" ] && [ -f "$A/stdout" ]; then
  echo "artifact: $A  status=$(cat "$A/status" 2>/dev/null || echo running)"
  # Plain text or JSON-escaped: \r\n to lines, ANSI colors stripped.
  out=$(perl -pe 's/\\r\\n/\n/g; s/\\u001b\[[0-9;]*m//g; s/\e\[[0-9;]*m//g; s/\r//g' "$A/stdout")
  # While the run is live, stdout is one JSON event per line; -o keeps only the header.
  echo "last play: $(echo "$out" | grep -aoE '^PLAY \[[^]]*\]' | tail -1)"
  echo "last task: $(echo "$out" | grep -aoE '^TASK \[[^]]*\]' | tail -1)"
  # Not anchored: in a JSON event the fatal line follows "stdout": " on the same line.
  f=$(echo "$out" | grep -aoE '(fatal|failed): \[[^]]*\]: .{0,250}' | tail -1); [ -n "$f" ] && echo "last fatal: $f"
  case "$out" in *"PLAY RECAP"*)
    echo "-- PLAY RECAP (failed or unreachable hosts):"
    echo "$out" | sed -n '/^PLAY RECAP/,$p' | grep -E 'failed=[1-9]|unreachable=[1-9]' || echo "   none" ;;
  esac
fi
gw=$(jq -r '.outputs.gateways.value[0].public_ip // empty' tf_cluster_aws/terraform.tfstate 2>/dev/null)
[ -n "$gw" ] || { echo "-- no gateway in terraform state (infrastructure not up)"; exit 0; }
CM="https://cm.$gw.nip.io"
PW=$(sed -n 's/^common_password: *"\(.*\)"/\1/p' "$CFG")
V=$(curl -ksf --max-time 10 -u "admin:$PW" "$CM/api/version")
if [ -n "$V" ]; then
  echo "-- CM $CM"
  for c in ozone-base-cluster "$PREFIX-ecs-cluster"; do
    curl -ks --max-time 15 -u "admin:$PW" "$CM/api/$V/clusters/$c" | jq -r --arg c "$c" '"cluster \($c): \(.entityStatus // "not created yet")"' 2>/dev/null
    curl -ks --max-time 15 -u "admin:$PW" "$CM/api/$V/clusters/$c/services" | jq -r '[.items[]? | "\(.name)=\(.serviceState)/\(.healthSummary)"] | join(" ")' 2>/dev/null
    curl -ks --max-time 15 -u "admin:$PW" "$CM/api/$V/clusters/$c/parcels" | jq -r '.items[]? | select(.stage | test("ING$")) | "  parcel \(.product) \(.version): \(.stage) \(.state.progress)/\(.state.totalProgress)"' 2>/dev/null
    curl -ks --max-time 15 -u "admin:$PW" "$CM/api/$V/clusters/$c/commands" | jq -r '.items[]? | "  active command: \(.name) since \(.startTime)"' 2>/dev/null
  done
else echo "-- CM $CM not answering (services or cms not finished, or your public IP changed: README, When it stops)"; fi
echo "ECS console https://console-cdp.apps.ecs.$gw.nip.io -> $(curl -ks --max-time 15 -o /dev/null -w '%{http_code}' "https://console-cdp.apps.ecs.$gw.nip.io")"
# cai-workbench.yml prints no URL; the workbench id is in the name of the Caddy file it writes on the gateway.
wb=$(ssh -F "$PREFIX-ssh.config" -o BatchMode=yes -o ConnectTimeout=15 jump ls /etc/caddy/Caddyfile.d/ 2>/dev/null | sed -n 's/^cloudera_cai_\(.*\)\.caddyfile$/\1/p' | head -1)
[ -n "$wb" ] && echo "AI Workbench https://$wb.apps.ecs.$gw.nip.io -> $(curl -ks --max-time 15 -o /dev/null -w '%{http_code}' "https://$wb.apps.ecs.$gw.nip.io")"
exit 0
