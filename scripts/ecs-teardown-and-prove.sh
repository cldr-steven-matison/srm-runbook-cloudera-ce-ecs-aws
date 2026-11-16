#!/usr/bin/env bash
# Tear the deployment down and prove nothing is left billing.
#   bash scripts/ecs-teardown-and-prove.sh            # starts the teardown detached in tmux and returns
#   bash scripts/ecs-teardown-and-prove.sh --prove    # the proof only, read-only, any time
# The proof counts EC2, EBS, VPCs and Elastic IPs tagged deployment=$PREFIX, plus any Elastic IP whose
# Name starts with the prefix but lost its tag. A VPC cannot be deleted while its NAT gateway exists, so
# VPC=0 covers the NAT gateway. A failed AWS call prints ERR, which is not 0: an expired session can
# never read as clean. The teardown log ends with one line, TEARDOWN END ... clean | LEFTOVERS.
set -euo pipefail
. "$(dirname "$0")/env.sh"
n() { aws "$@" --profile "$PROFILE" --region "$REGION" --output text 2>/dev/null || echo ERR; }

prove() {
  local ec2 ebs vpc eip eipname
  ec2=$(n ec2 describe-instances --filters "Name=tag:deployment,Values=$PREFIX" "Name=instance-state-name,Values=running,pending,stopping,stopped" --query 'length(Reservations[].Instances[])')
  ebs=$(n ec2 describe-volumes --filters "Name=tag:deployment,Values=$PREFIX" --query 'length(Volumes)')
  vpc=$(n ec2 describe-vpcs --filters "Name=tag:deployment,Values=$PREFIX" --query 'length(Vpcs)')
  eip=$(n ec2 describe-addresses --filters "Name=tag:deployment,Values=$PREFIX" --query 'length(Addresses)')
  # Tags[?...] on an untagged address is null, not an error; the account holds other people's addresses.
  eipname=$(n ec2 describe-addresses --query "length(Addresses[?Tags[?Key=='Name' && starts_with(Value, '$PREFIX-')]])")
  echo "EC2=$ec2 EBS=$ebs VPC=$vpc EIP(tagged)=$eip EIP(named)=$eipname"
  [ "$ec2" = 0 ] && [ "$ebs" = 0 ] && [ "$vpc" = 0 ] && [ "$eip" = 0 ] && [ "$eipname" = 0 ]
}

case "${1:-}" in
--prove) prove; exit $? ;;
--in-tmux) ;;
"")
  tmux has-session -t "$SESSION" 2>/dev/null && { echo "NOT LAUNCHED: tmux session $SESSION exists; one run at a time" >&2; exit 1; }
  aws sts get-caller-identity --profile "$PROFILE" --output text --query Arn >/dev/null 2>&1 || { echo "NOT LAUNCHED: AWS creds: run  aws sso login --profile $PROFILE  then retry" >&2; exit 1; }
  mkdir -p "$ECS_REPO/runs"
  LOG="$ECS_REPO/runs/$(date -u +%Y%m%dT%H%M)-teardown.log"
  tmux new-session -d -s "$SESSION" env PATH="$PATH" bash -c "bash '$HERE/ecs-teardown-and-prove.sh' --in-tmux > '$LOG' 2>&1"
  echo "launched: infrastructure-teardown.yml  (tmux session $SESSION)"
  echo "log:      $LOG"
  echo "wait:     bash scripts/ecs-wait.sh"
  exit 0 ;;
*) echo "usage: $0 [--prove]" >&2; exit 2 ;;
esac

# Inside tmux from here on.
cd "$ECS_REPO"
export PATH="$VENV/bin:$PATH"
eval "$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN aws configure export-credentials --format env --profile "$PROFILE")"
rc=0; ansible-navigator run playbooks/infrastructure-teardown.yml -e @"$CFG" -m stdout || rc=$?
if proof=$(prove); then v=clean; else v=LEFTOVERS; fi
if [ $v = clean ]; then
  # The files the run generated for a gateway that no longer exists: the workbench TLS key and certs,
  # the Caddy root cert and the URL summary. The runs/ logs stay as the record of the run.
  rm -f playbooks/*.nip.io.crt playbooks/*.nip.io.pem "playbooks/$PREFIX-caddy-root.crt" "$PREFIX-caddy-root.crt" "$PREFIX-summary.html"
else
  echo "LEFTOVERS: release or delete by id only on an explicit yes:"
  aws ec2 describe-addresses --query "Addresses[?Tags[?Key=='Name' && starts_with(Value, '$PREFIX-')]].[AllocationId,PublicIp,AssociationId]" --profile "$PROFILE" --region "$REGION" --output text || true
fi
echo "TEARDOWN END $(date -u "+%Y-%m-%d %H:%M:%S") UTC: navigator rc=$rc, $proof $v"
