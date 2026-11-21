#!/usr/bin/env bash
# Runs `terraform apply` with JSON output and prints it as readable lines.
# Why: Terraform 1.14.1 can crash ("panic: unknown type implementation") while drawing the
# human-readable plan summary. The JSON output path does not use that renderer.
# Usage: scripts/tf-apply.sh [extra terraform apply args, e.g. -var image_tag=abc | -destroy]
set -euo pipefail
cd "$(dirname "$0")/.."
terraform -chdir=infra apply -input=false -auto-approve -json "$@" | python3 -u -c '
import sys, json
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        print(line, end="")
        continue
    msg = m.get("@message", "")
    if msg:
        print(msg)
    d = m.get("diagnostic")
    if d:
        if d.get("detail"):
            print("    " + d["detail"].replace("\n", "\n    "))
        if d.get("address"):
            print("    resource: " + d["address"])
'
