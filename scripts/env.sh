# Sourced by every script in scripts/. The one place these names live.
export ECS_REPO="$HOME/Documents/GitHub/cloudera-ce-ecs-aws"   # the fork clone, branch srm-561
export CDP_LICENSE_FILE="$HOME/license.txt"                    # the only license file
export VENV="$HOME/.venvs/cdp-navigator"
export PREFIX=srmecs                                           # name_prefix, and the AWS deployment tag
export PROFILE=cldr-se                                         # AWS SSO profile
export REGION=us-east-2
export CFG=config-srm-ecs.yml                                  # in $ECS_REPO, mode 600, git-excluded
export KEYS="$HOME/.config/ecs-aws/cp-keys.env"                # the Control Plane access keys
export SESSION=srmecs                                          # the tmux session every run lives in
export AWS_PAGER=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HERE
