#!/bin/bash
set -euo pipefail

cat <<'EOF'
COMPACTION OCCURRING — After compaction, restore your working context:
1. Check task list (TaskList) for in-progress work
2. Check MEMORY.md for persistent context
3. Re-read any files you were actively editing before continuing
EOF

exit 0
