# Cloudera Private Cloud ECS on AWS from a Mac: Base, ECS and an AI Workbench

I want an ECS Private Cloud I can stand up from my laptop, demo and tear down the same day.
[`cloudera-labs/cloudera-ce-ecs-aws`](https://github.com/cloudera-labs/cloudera-ce-ecs-aws) already does
the work with one config file and one `ansible-navigator run` of five playbooks. This repo is everything
around that command: a config template, a launcher with a preflight, a status view, and a teardown that
checks nothing is left billing. It also has a step card, so Claude Code, or a local model running under
Claude Code, can drive the run while you approve each launch.

The playbooks run from a fork, [`cldr-steven-matison/cloudera-ce-ecs-aws`](https://github.com/cldr-steven-matison/cloudera-ce-ecs-aws),
branch `srm-561`. It is upstream plus four changes, also described in the fork's README:

- `6ed68ea` pins the execution environment by digest and mounts `patches/RedHat-pre.yml` over the
  `cloudera.exe` Caddy role. The stock role runs `dnf copr enable @caddy/caddy`, which RHEL 9 EC2 hosts
  without a Red Hat subscription cannot reach.
- `29a9ffc` pins the Terraform host and network modules to commit `c5b5981` instead of `main`.
- `539f459` and `420b21a` run the two ECS-master kubernetes plays in `ecs-cluster.yml` on
  `/usr/bin/python3`. The hosts get Python 3.11 as `python3`, and the play installs the `kubernetes`
  library there. Two `cloudera.exe` roles set the interpreter to `/usr/libexec/platform-python` (3.9),
  which cannot import it, and `420b21a` overrides them with a `set_fact`.

## Status

Not verified. No full run has passed yet. Each one stopped part way:

| Date | Stopped in | Log line |
|---|---|---|
| 2026-11-12 | `ecs-cluster` | `Failed to import the required Python library (kubernetes)`; it passed only after a fix and a re-run of `ecs-cluster` on its own |
| 2026-11-13 | `cms` | `Failed to download metadata for repo 'cloudera-manager'`: the license had expired |
| 2026-11-13 | `ecs-cluster` | the same kubernetes error; the 11-12 fix did not hold in a full run, and `420b21a` replaces it |
| 2026-11-16 | `services` | `Failed to download packages: postgresql14-server-14.25-1PGDG.rhel9.8.x86_64`: PGDG had removed the file |

It counts as verified when one `bash scripts/ecs-run.sh` from the start ends
`RUN END ... status=successful`, with no fix and no re-run in between. That line goes here when it
happens.

## What it builds and what it costs

15 EC2 instances in `us-east-2`. The instance types are hardcoded in `tf_cluster_aws/hosts_*.tf`.

| Group | Type | Count |
|---|---|---|
| gateway (Caddy, SSH jump host) | t3a.medium | 1 |
| services (FreeIPA, PostgreSQL) | t3a.large | 1 |
| manager (Cloudera Manager) | r5a.xlarge | 1 |
| SDX, Base masters, Base workers | t3a.xlarge | 1 + 3 + 4 |
| ECS master, ECS workers | r5a.4xlarge | 1 + 3 |

That is 104 vCPU, about 5.2 TB of EBS, a NAT gateway and two Elastic IPs: about **$6 an hour**.
Paused, the EBS, the NAT gateway and the addresses keep billing at about $0.65 an hour. Expect about
4 hours of playbooks for Base and ECS, 11 minutes for the AI Workbench and 5 minutes for the teardown.

## What you need

| Item | Value |
|---|---|
| Accounts | an AWS account you can deploy into, and a Cloudera license |
| Tools | `aws` CLI v2, `jq`, `tmux`, `curl`, `perl`, `git`, `python3`, `uv`, Docker Desktop |
| Fork clone | `~/Documents/GitHub/cloudera-ce-ecs-aws`, branch `srm-561` |
| This repo | `~/Documents/GitHub/srm-runbook-cloudera-ce-ecs-aws` |
| Navigator | `~/.venvs/cdp-navigator`, Python 3.12, `ansible-navigator` |
| License | `~/license.txt`, the PGP-signed Cloudera license |
| AWS | an SSO profile, `cldr-se` here. The launcher exports its role credentials into the execution environment, which does not read `--profile` |

Every path and name above is set in one file, [`scripts/env.sh`](scripts/env.sh). Change them there to
match your machine and AWS profile.

## One-time setup

```bash
git clone --branch srm-561 https://github.com/cldr-steven-matison/cloudera-ce-ecs-aws.git ~/Documents/GitHub/cloudera-ce-ecs-aws
git clone https://github.com/cldr-steven-matison/srm-runbook-cloudera-ce-ecs-aws.git ~/Documents/GitHub/srm-runbook-cloudera-ce-ecs-aws
uv python install 3.12
uv venv ~/.venvs/cdp-navigator --python 3.12
uv pip install --python ~/.venvs/cdp-navigator/bin/python ansible-navigator
docker pull ghcr.io/cloudera-labs/cloudera-ce-ecs-aws@sha256:855d5b0a929d2483adedd6b47991da7af4fafa8572d6c5c013ae1d52b856b3a1
cd ~/Documents/GitHub/cloudera-ce-ecs-aws
cp ~/Documents/GitHub/srm-runbook-cloudera-ce-ecs-aws/config.example.yml config-srm-ecs.yml
chmod 600 config-srm-ecs.yml
echo config-srm-ecs.yml >> .git/info/exclude
python3 ~/Documents/GitHub/srm-runbook-cloudera-ce-ecs-aws/scripts/license-creds.py >> config-srm-ecs.yml
mkdir -p -m 700 ~/.config/ecs-aws
```

Then fill the `CHANGEME` values in `config-srm-ecs.yml` by hand. The two passwords follow different
rules. `common_password` is letters and digits only, because Cloudera Manager, FreeIPA and PostgreSQL
receive it inside basic-auth URLs. `cloudera_ecs_admin_password` needs an upper, a lower, a digit and
a `_` or `.`. The `license-creds.py` lines are the archive.cloudera.com repo credentials; with them set,
`cms.yml` never derives them per host.

## Run it

Before the first command, start Docker Desktop, put the Mac on AC power with the lid open, and keep the
VPN **in one state for the whole run**, connected or not. The security group admits one `/32`, your public
IP at apply time (`api.ipify.org`). Switching the VPN, or a VPN reconnect that lands on a new egress,
changes that IP and locks you out.

```bash
cd ~/Documents/GitHub/srm-runbook-cloudera-ce-ecs-aws
aws sso login --profile cldr-se
bash scripts/ecs-run.sh --check      # preflight ok, or PREFLIGHT FAILED: <what> and the fix
bash scripts/ecs-run.sh              # the five playbooks; about $6/h from here
bash scripts/ecs-wait.sh             # waits up to 9 minutes, then prints the status
```

`ecs-run.sh` returns at once. The run lives in tmux session `srmecs` and survives the terminal that
started it. Repeat `ecs-wait.sh` (or `ecs-status.sh`, which does not wait) until the log line reads:

```text
RUN END 2026-01-01 18:40:12 UTC: navigator rc=0, runs/artifacts/<id>/ status=successful
```

The status shows the newest artifact's last play, task and fatal line, any failed or unreachable host,
both clusters and their services, any parcel in flight, and the ECS console's HTTP code.

A resume is the failed playbook and every one after it, for example
`bash scripts/ecs-run.sh cms ozone-cluster ecs-cluster`. The playbooks are idempotent.

## The Control Plane keys, then the AI Workbench

`cai-workbench.yml` calls the ECS Control Plane API, and its keys exist only once the Control Plane is
up. This is the one step you do by hand.

1. Open the `ECS console` URL that `ecs-status.sh` prints and log in as `admin` with
   `cloudera_ecs_admin_password`.
2. User Profile → Generate Access Key. Copy the whole private key. It is 44 characters, and any other
   length fails with `Only ed25519v1 keys are supported!`.
3. Write the three exports to `~/.config/ecs-aws/cp-keys.env`, then `chmod 600` it:

   ```bash
   export CDP_ACCESS_KEY_ID=...
   export CDP_PRIVATE_KEY=...
   export CDP_ENDPOINT_URL=https://console-cdp.apps.ecs.<gateway ip>.nip.io
   ```

4. Run the workbench:

   ```bash
   bash scripts/ecs-run.sh --check cai-workbench   # tests the file mode and the key length
   bash scripts/ecs-run.sh cai-workbench
   bash scripts/ecs-wait.sh
   ```

The workbench quota is 50 CPU and 46 GiB. ECS at this size carries one data service at a time.

## Done

- `RUN END ... status=successful` for the five playbooks and for `cai-workbench`.
- `ecs-status.sh` shows `cluster ozone-base-cluster: GOOD_HEALTH`, `cluster srmecs-ecs-cluster: GOOD_HEALTH`,
  the ECS console at 302 and the `AI Workbench` line at 200.
- After the teardown, `ecs-teardown-and-prove.sh --prove` prints all zeros.

## When it stops

| Log line | Check | Fix |
|---|---|---|
| `PREFLIGHT FAILED: <what>` | the line | the fix it names |
| `PREFLIGHT FAILED: the license expired on <date>` | `expirationDate` in `~/license.txt` | put the renewed license in `~/license.txt`, then replace the two `cloudera_manager_repo_*` lines in `config-srm-ecs.yml` with the `license-creds.py` output |
| `Failed to download metadata for repo 'cloudera-manager'` | `ecs-run.sh --check`, which tests the repo for a 200 | a 403 means archive.cloudera.com refuses the license: renew it as in the row above, then resume from `cms` |
| `Failed to download packages: postgresql14-server-…` on `srmecs-services-01` | `ecs-run.sh --check`, which fetches that RPM from download.postgresql.org | PGDG is not serving the file: tear down, or wait, and resume `ecs-run.sh services cms ozone-cluster ecs-cluster` once the check passes |
| `AWS credentials are expired or not configured!` | `aws sts get-caller-identity --profile cldr-se` | `aws sso login --profile cldr-se`, then the same `ecs-run.sh` command |
| `'common_password' is undefined` | the command in the log | the playbook ran without `ecs-run.sh`; launch it through the script |
| `cloudera_ecs_admin_password must be at least 8 characters…` | the config | fix the value, then `ecs-run.sh ecs-cluster` |
| SSH or `wait_for_connection` timeouts, or CM stops answering | `curl -4 -s ifconfig.me` against the prefix list | your public IP changed: add the new `/32` (below), then resume from the failed playbook |
| `Unable to parse license JSON` | `grep -c ^cloudera_manager_repo config-srm-ecs.yml` is 2 | append the `license-creds.py` output, resume from `cms` |
| `Group hadoop does not exist` on one host | the host is missing from CM's host list | its agent missed the install: re-run CM's `hostInstall` for that host, then resume from `ozone-cluster` |
| a parcel at `DISTRIBUTING n/N` with no active command | `ecs-status.sh` | wait; it can sit 50 minutes and then go straight to `ACTIVATED` |
| clusters `BAD` or `CONCERNING` during First Run | `ecs-status.sh` again in 10 minutes | normal while First Run restarts the cluster |
| a Base worker stops answering, or a DataNode runs out of memory | the PLAY RECAP `unreachable=` hosts | reboot that EC2 instance, then resume |
| `Failed to import the required Python library (kubernetes)` on `srmecs-ecs-master-01` | `git -C ~/Documents/GitHub/cloudera-ce-ecs-aws merge-base --is-ancestor 420b21a HEAD && echo ok` | no `ok`: the clone lacks `420b21a`, so pull `srm-561`, then `ecs-run.sh ecs-cluster` |
| `Only ed25519v1 keys are supported!` | `ecs-run.sh --check cai-workbench` | copy the 44-character private key again, then `ecs-run.sh cai-workbench` |
| any other failure in `ecs-cluster` or `cai-workbench` | `ecs-status.sh` | stop and read the play before a rerun |
| `LEFTOVERS` after the teardown | the ids it lists | release or delete them by id |

To add a new public IP to the ingress prefix list:

```bash
aws ec2 describe-managed-prefix-lists --filters Name=prefix-list-name,Values=srmecs-pvc-base-ingress --query 'PrefixLists[0].[PrefixListId,Version,MaxEntries]' --output text --profile cldr-se --region us-east-2
aws ec2 modify-managed-prefix-list --prefix-list-id <pl-id> --max-entries <MaxEntries+1> --profile cldr-se --region us-east-2
# describe again for the current Version, then:
aws ec2 modify-managed-prefix-list --prefix-list-id <pl-id> --current-version <Version> --add-entries Cidr=<new ip>/32 --profile cldr-se --region us-east-2
```

## Pause and teardown

```bash
bash scripts/ecs-run.sh pause                       # stop the 15 instances, keep the EBS
bash scripts/ecs-run.sh resume                      # start them again
bash scripts/ecs-teardown-and-prove.sh              # the teardown, detached in tmux
bash scripts/ecs-wait.sh                            # until the TEARDOWN END line
bash scripts/ecs-teardown-and-prove.sh --prove      # read-only, any time
```

`pause` and `resume` run the fork's `pause.yml` and `resume.yml`. I have not run them yet; the
teardown has run several times.

The teardown runs `infrastructure-teardown.yml`, then counts what is left for `deployment=srmecs`:

```text
TEARDOWN END 2026-01-01 19:53:02 UTC: navigator rc=0, EC2=0 EBS=0 VPC=0 EIP(tagged)=0 EIP(named)=0 clean
```

`VPC=0` covers the NAT gateway, since a VPC cannot be deleted while one exists. `EIP(named)` catches an
address named `srmecs-…` that lost its tag. A failed AWS call reads `ERR`, which is not clean. On
`clean` the script also deletes what the run generated in the fork clone for the old gateway: the
workbench TLS key and certs in `playbooks/`, the Caddy root cert and `srmecs-summary.html`. The `runs/`
logs stay. Then delete `~/.config/ecs-aws/cp-keys.env`; its keys belong to a Control Plane that no
longer exists.

## Reaching it

Everything sits behind Caddy on the gateway and answers only from the `/32` in the prefix list.

| What | URL | Login |
|---|---|---|
| Cloudera Manager | `https://cm.<gateway ip>.nip.io` | `admin` / `common_password` |
| ECS Control Plane | `https://console-cdp.apps.ecs.<gateway ip>.nip.io` | `admin` / `cloudera_ecs_admin_password` |
| AI Workbench | the `AI Workbench` line of `ecs-status.sh` | through the Control Plane |
| a host shell | `ssh -F ~/Documents/GitHub/cloudera-ce-ecs-aws/srmecs-ssh.config jump` | the generated key |

The other service URLs are in `srmecs-summary.html` in the fork clone.

## Running it with an agent

[`card.yml`](card.yml) is the run as steps. Each step has a command, the strings that mean success or
failure, and whether it needs your yes. [`CLAUDE.md`](CLAUDE.md) tells Claude Code to follow it, and
[`.claude/settings.json`](.claude/settings.json) allows only the read-only scripts without a prompt and
denies `ansible-navigator`, `terraform`, `aws` and `rm` outright. Every launch is a permission prompt,
and approving the prompt is your yes.

Two hooks in the same file hold the agent to the card whether it follows `CLAUDE.md` or not:

- [`card-commands-only.sh`](.claude/hooks/card-commands-only.sh) refuses any shell command that is not
  in `card.yml` exactly as written. The only extras are a resume (`ecs-run.sh` with playbook names) and
  `ecs-wait.sh` with a timeout.
- [`keep-watching.sh`](.claude/hooks/keep-watching.sh) refuses to let the agent end its turn while the
  `srmecs` tmux session exists, and tells it to run `bash scripts/ecs-wait.sh`.

The same files drive a local model. Serve Gemma 4 with Ollama, start Claude Code against it from this
directory, and ask it to run `card.yml`:

```bash
OLLAMA_HOST=127.0.0.1:11434 OLLAMA_NO_CLOUD=1 OLLAMA_CONTEXT_LENGTH=65536 ollama serve
cd ~/Documents/GitHub/srm-runbook-cloudera-ce-ecs-aws
claude-ollama          # claude with ANTHROPIC_BASE_URL=http://127.0.0.1:11434 and the model set to gemma4:26b-mlx
```

## What not to do

- Run `ansible-navigator`, `terraform` or a playbook except through `ecs-run.sh`, or start a second run
  while tmux session `srmecs` exists.
- Repair a failed apply by deleting AWS resources or `terraform.tfstate` by hand. The teardown is the
  only exit.
- Reuse `srmecs` for a second deployment, or run it from a second machine. Terraform state is a local
  file in the fork clone.
- Paste the passwords, the repo credentials or the Control Plane keys into chat, an issue or git.
