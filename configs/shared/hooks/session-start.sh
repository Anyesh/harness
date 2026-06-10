#!/bin/bash

INPUT=$(cat 2>/dev/null || true)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=load-harness-env.sh
source "$HOOK_DIR/load-harness-env.sh"
load_wiki_vault

python3 <<'PY'
import json
import os

env = {"RTK_TELEMETRY_DISABLED": "1"}
wiki = os.environ.get("WIKI_VAULT", "")
if wiki:
    env["WIKI_VAULT"] = wiki

print(json.dumps({"env": env}))
PY

exit 0
