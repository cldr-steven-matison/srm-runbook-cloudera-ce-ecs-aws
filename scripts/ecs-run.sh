#!/usr/bin/env bash
# The one way to launch the playbooks. Checks the license, the config, the navigator, Docker, AWS and
# that no run is in progress, then starts ansible-navigator detached in tmux, so the run outlives the
# terminal or agent that started it.
#   bash scripts/ecs-run.sh --check                          # the checks only, read-only
#   bash scripts/ecs-run.sh                                  # infrastructure services cms ozone-cluster ecs-cluster
#   bash scripts/ecs-run.sh cms ozone-cluster ecs-cluster    # resume: the failed playbook and every one after it
#   bash scripts/ecs-run.sh --check cai-workbench            # the checks, including the Control Plane keys
#   bash scripts/ecs-run.sh cai-workbench                    # the AI Workbench, after the Control Plane keys
#   bash scripts/ecs-run.sh pause | resume                   # stop or start the instances
set -euo pipefail
. "$(dirname "$0")/env.sh"
cd "$ECS_REPO"
check=0; [ "${1:-}" = "--check" ] && { check=1; shift; }
books=("$@"); [ ${#books[@]} -eq 0 ] && books=(infrastructure services cms ozone-cluster ecs-cluster)
fail() { echo "PREFLIGHT FAILED: $*" >&2; exit 1; }
[ -f "$CDP_LICENSE_FILE" ] && head -1 "$CDP_LICENSE_FILE" | grep -q 'BEGIN PGP SIGNED MESSAGE' || fail "$CDP_LICENSE_FILE missing or not the PGP-signed Cloudera license; never create another"
[ -f "$CFG" ] || fail "no $ECS_REPO/$CFG: README, One-time setup"
grep -qE '^[a-z_]+: *"CHANGEME"' "$CFG" && fail "$CFG still has CHANGEME values"
grep -qE '^common_password: *"[[:alnum:]]{8,}"' "$CFG" || fail "common_password must be 8+ letters and digits only"
ep=$(sed -n 's/^cloudera_ecs_admin_password: *"\(.*\)"/\1/p' "$CFG")
[ ${#ep} -ge 8 ] && [[ $ep =~ [[:upper:]] && $ep =~ [[:lower:]] && $ep =~ [[:digit:]] && $ep =~ [._] ]] || fail "cloudera_ecs_admin_password needs 8+, an upper, a lower, a digit and _ or ."
grep -q '^cloudera_manager_repo_username:' "$CFG" || fail "$CFG lacks the repo credentials: python3 $HERE/license-creds.py >> $CFG"
# archive.cloudera.com refuses an expired license with a 403, which the hosts hit at the cms playbook.
lic_end=$(python3 -c 'import json,sys; t=open(sys.argv[1]).read(); j=json.loads(t[t.index("{"):t.index("}")+1]); print(min(j.get("expirationDate","9999-12-31"), j.get("deactivationDate","9999-12-31")))' "$CDP_LICENSE_FILE") || fail "cannot read the license JSON in $CDP_LICENSE_FILE"
[[ "$(date -u +%F)" > "$lic_end" ]] && fail "the license expired on $lic_end: put the renewed license in $CDP_LICENSE_FILE, then replace the two cloudera_manager_repo_* lines in $CFG with the output of python3 $HERE/license-creds.py"
rel=$(sed -n 's/^cloudera_manager_release: *"\{0,1\}\([0-9.]*\).*/\1/p' "$CFG" | head -1)
[ -n "$rel" ] || rel=$(sed -n 's/^cloudera_manager_release: *"\{0,1\}\([0-9.]*\).*/\1/p' group_vars/all.yml | head -1)
repo="https://archive.cloudera.com/p/cm7/$rel/redhat9/yum/repodata/repomd.xml"
ru=$(sed -n 's/^cloudera_manager_repo_username: *"\(.*\)"/\1/p' "$CFG"); rp=$(sed -n 's/^cloudera_manager_repo_password: *"\(.*\)"/\1/p' "$CFG")
# The credentials go to curl on stdin, never on the command line.
code=$(printf 'user = "%s:%s"\n' "$ru" "$rp" | curl -s -K - -o /dev/null -w '%{http_code}' --max-time 30 "$repo")
[ "$code" = 200 ] || fail "the Cloudera Manager repo answered $code, not 200: $repo (403: the license or the repo credentials in $CFG are not accepted; 401: no credentials)"
grep -q 'ECS_REPO}/patches/RedHat-pre.yml' ansible-navigator.yml && [ -f patches/RedHat-pre.yml ] || fail "the clone is not on srm-561: git -C $ECS_REPO switch srm-561"
# A clone behind GitHub runs old code and an old card, so both must match their branch on GitHub.
for r in "$ECS_REPO" "$(cd "$HERE/.." && pwd)"; do
  git -C "$r" fetch -q origin 2>/dev/null || fail "git fetch failed in $r"
  [ -z "$(git -C "$r" status --porcelain --untracked-files=no)" ] || fail "$r has uncommitted changes"
  [ "$(git -C "$r" rev-parse HEAD)" = "$(git -C "$r" rev-parse '@{u}')" ] || fail "$r does not match $(git -C "$r" rev-parse --abbrev-ref '@{u}'): git -C $r pull --ff-only"
done
for b in "${books[@]}"; do [ -f "playbooks/$b.yml" ] || fail "playbooks/$b.yml not found"; done
# services installs PostgreSQL 14 from PGDG. On 2026-11-16 PGDG listed its newest server RPM but answered
# 404 for it, and the run stopped 70 minutes in. Fetching the first KB here finds that at minute zero.
pg=; case " ${books[*]} " in *" services "*)
  pgdg=https://download.postgresql.org/pub/repos/yum/14/redhat/rhel-9-x86_64
  pm=$(curl -s --max-time 30 "$pgdg/repodata/repomd.xml" | grep -o 'repodata/[^"]*-primary\.xml\.gz' || true)
  [ -n "$pm" ] || fail "cannot read the PGDG repo metadata: $pgdg/repodata/repomd.xml"
  rpm=$(curl -s --max-time 60 "$pgdg/$pm" | gunzip | grep -o 'postgresql14-server-[^"]*\.x86_64\.rpm' | sort -V | tail -1 || true)
  [ -n "$rpm" ] || fail "no postgresql14-server in the PGDG metadata: $pgdg/$pm"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -r 0-1023 "$pgdg/$rpm")
  [[ $code = 20[06] ]] || fail "PGDG answered $code for $rpm, so the services playbook cannot install PostgreSQL: wait until it answers 200, then retry (README, When it stops)"
  pg=", PGDG 200" ;;
esac
keys=; case " ${books[*]} " in *" cai-workbench "*)
  keys=$KEYS
  case "$(ls -l "$KEYS" 2>/dev/null)" in -rw-------*) ;; *) fail "$KEYS missing or not mode 600: README, The Control Plane keys" ;; esac
  # cloudera.cloud accepts only an ed25519 private key, which is 44 characters.
  [ "$(bash -c '. "$1"; printf %s "${#CDP_PRIVATE_KEY}"' _ "$KEYS")" = 44 ] || fail "CDP_PRIVATE_KEY in $KEYS is not 44 characters: copy the whole private key from the console again" ;;
esac
[ -x "$VENV/bin/ansible-navigator" ] || fail "no $VENV: README, One-time setup"
docker info >/dev/null 2>&1 || fail "Docker is not running: start Docker Desktop"
tmux has-session -t "$SESSION" 2>/dev/null && fail "tmux session $SESSION exists: a run is in progress (scripts/ecs-status.sh); one run at a time"
pgrep -f 'ansible-navigator run playbooks/[a-z]' >/dev/null && fail "a run is already in progress: $(pgrep -lf 'ansible-navigator run' | head -1 | cut -c1-120)"
[ -n "$(docker ps -q --filter name=ansible_runner_)" ] && fail "a runner container is still up: $(docker ps --format '{{.Names}}' --filter name=ansible_runner_)"
aws sts get-caller-identity --profile "$PROFILE" --output text --query Arn >/dev/null 2>&1 || fail "AWS creds: run  aws sso login --profile $PROFILE  then retry"
if [ $check -eq 1 ]; then echo "preflight ok: license (to $lic_end), CM repo 200$pg, clones match GitHub, config, navigator, creds, no run in progress; playbooks: ${books[*]}"; exit 0; fi
args=(); for b in "${books[@]}"; do args+=("playbooks/$b.yml"); done
mkdir -p runs
LOG="runs/$(date -u +%Y%m%dT%H%M)-${books[0]}.log"
# The tmux server keeps the environment it started with, so the run's needs go in by env. The execution
# environment reads AWS env vars, not --profile; stale ones are dropped so the export reads the SSO session.
tmux new-session -d -s "$SESSION" env ECS_REPO="$ECS_REPO" CDP_LICENSE_FILE="$CDP_LICENSE_FILE" PATH="$VENV/bin:$PATH" \
  LOG="$LOG" KEYS="$keys" CFG="$CFG" PROFILE="$PROFILE" BOOKS="${args[*]}" bash -c '
  cd "$ECS_REPO" || exit 1
  [ -z "$KEYS" ] || . "$KEYS"
  eval "$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN aws configure export-credentials --format env --profile "$PROFILE")"
  C=; command -v caffeinate >/dev/null && C="caffeinate -dims"
  $C ansible-navigator run $BOOKS -e @"$CFG" -m stdout > "$LOG" 2>&1; rc=$?
  A=$(ls -td runs/artifacts/*/ 2>/dev/null | head -1)
  echo "RUN END $(date -u "+%Y-%m-%d %H:%M:%S") UTC: navigator rc=$rc, ${A:-no artifact} status=$(cat "${A}status" 2>/dev/null)" >> "$LOG"'
echo "launched: ansible-navigator run ${args[*]} -e @$CFG  (tmux session $SESSION)"
echo "log:      $ECS_REPO/$LOG   (buffered until the run ends; the live view is scripts/ecs-status.sh)"
echo "wait:     bash scripts/ecs-wait.sh"
