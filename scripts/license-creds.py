#!/usr/bin/env python3
"""Print the archive.cloudera.com repo credentials derived from the Cloudera license, as YAML to append
to config-srm-ecs.yml: username = license uuid, password = sha256(name + uuid)[:12], the derivation
cloudera.cluster's cm_license lookup uses. With them set as extra-vars the lookup never runs.
Usage: python3 scripts/license-creds.py [~/license.txt] >> config-srm-ecs.yml"""
import hashlib, json, sys, os
p = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/license.txt')
t = open(p).read(); j = json.loads(t[t.index('{'):t.index('}') + 1])
print(f'cloudera_manager_repo_username: "{j["uuid"]}"')
print(f'cloudera_manager_repo_password: "{hashlib.sha256((j["name"] + j["uuid"]).encode()).hexdigest()[:12]}"')
