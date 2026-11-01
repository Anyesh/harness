#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CB="$REPO_ROOT/configs/claude-code/bin/crew-board"
# shellcheck source=../configs/claude-code/bin/crew-lib.sh
. "$REPO_ROOT/configs/claude-code/bin/crew-lib.sh"

PASS=0
FAIL=0

assert() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    printf '        out: %s\n' "${OUT//$'\n'/$'\n             '}"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+w "$TMP_DIR"; command rm -rf "$TMP_DIR"' EXIT

REPO="$TMP_DIR/repo"
git init -q "$REPO"
CREW="$REPO/.claude/crew"
mkdir -p "$CREW"
BOARD="$CREW/board.tsv"

OUT=
RC=0
cb() {
  RC=0
  OUT=$(cd "$REPO" && "$CB" "$@" 2>&1) || RC=$?
}
field() { awk -F'\t' -v id="$1" -v n="$2" '($1 "") == id "" {print $n}' "$BOARD"; }
nf() { awk -F'\t' -v id="$1" '$1 == id {print NF}' "$BOARD"; }
unchanged() { cmp -s "$BOARD" "$TMP_DIR/before"; }
snap() { command cp "$BOARD" "$TMP_DIR/before"; }

echo "add"
t0=$(date +%s)
cb add 1 main "first deliverable"
assert "add writes an open row with branch w/<id>, an empty owner and the time" '[[ $RC -eq 0 && $(nf 1) -eq 8 && $(field 1 2) == open && -z $(field 1 3) && $(field 1 4) == w/1 && $(field 1 5) == main && $(field 1 7) == "first deliverable" && -z $(field 1 8) ]] && (($(field 1 6) >= t0))'
cb add 2 release "second" 1
assert "add takes deps" '[[ $RC -eq 0 && $(field 2 8) == 1 && $(field 2 5) == release ]]'
rows=$(crew_board "$BOARD" | awk -F'\037' '{print NF}' | sort -u)
assert "a row added without deps reads back through crew_board with 8 fields" '[[ $rows == 8 ]]'

snap
cb add 1 main "again"
assert "add rejects a duplicate id and leaves the board" '[[ $RC -ne 0 ]] && unchanged && grep -q "already" <<<"$OUT"'
cb add "a/b" main "x"
assert "add rejects an id that is not a plain name" '[[ $RC -ne 0 ]] && unchanged'
cb add 3 main $'has\ttab'
assert "add rejects a value with a tab" '[[ $RC -ne 0 ]] && unchanged && grep -q "tab or newline" <<<"$OUT"'
cb add 3 main $'has\nnewline'
assert "add rejects a value with a newline" '[[ $RC -ne 0 ]] && unchanged'
cb add 3 main ""
assert "add rejects an empty deliverable" '[[ $RC -ne 0 ]] && unchanged'
cb add 3
assert "add with too few arguments is a usage error" '[[ $RC -eq 2 ]] && unchanged'

echo "set"
t0=$(date +%s)
cb set 1 status=assigned owner=x-w1
assert "set changes the named fields and stamps updated now" '[[ $RC -eq 0 && $(field 1 2) == assigned && $(field 1 3) == x-w1 && $(field 1 7) == "first deliverable" ]] && (($(field 1 6) >= t0))'
cb set 1 updated=123 deliverable="new words" deps=2 into=dev
assert "set takes an explicit updated, deliverable, deps and into" '[[ $RC -eq 0 && $(field 1 6) == 123 && $(field 1 7) == "new words" && $(field 1 8) == 2 && $(field 1 5) == dev ]]'
cb set 1 owner= deps=
assert "set clears a field given an empty value" '[[ $RC -eq 0 && -z $(field 1 3) && -z $(field 1 8) && $(nf 1) -eq 8 ]]'

cb set 1 updated=5
t0=$(date +%s)
cb set 1
assert "set with only an id stamps updated now" '[[ $RC -eq 0 ]] && (($(field 1 6) >= t0))'

snap
cb set 01 status=done
assert "an id is matched as text, so 01 is not row 1" '[[ $RC -ne 0 ]] && unchanged'
cb add 01 main "zero one"
assert "add accepts 01 beside an existing 1" '[[ $RC -eq 0 && $(field 01 7) == "zero one" && $(field 1 7) == "new words" ]]'
command sed -i '/^01	/d' "$BOARD"

snap
cb set 9 status=done
assert "set rejects an unknown id" '[[ $RC -ne 0 ]] && unchanged && grep -q "not on the board" <<<"$OUT"'
cb set 1 branch=w/9
assert "set rejects a field it does not edit" '[[ $RC -ne 0 ]] && unchanged'
cb set 1 status=finished
assert "set rejects an invalid status" '[[ $RC -ne 0 ]] && unchanged'
cb set 1 updated=soon
assert "set rejects an updated that is not epoch seconds" '[[ $RC -ne 0 ]] && unchanged'
cb set 1 owner=$'a\tb'
assert "set rejects a value with a tab" '[[ $RC -ne 0 ]] && unchanged'
cb set 1 status
assert "set rejects an argument without =" '[[ $RC -ne 0 ]] && unchanged'

echo "rows it does not touch"
printf '7\tdone\tx-w7\tw/7\tmain\t5\thand written\n' >>"$BOARD"
printf '8\topen\t\tw/8\tmain\t6\tno newline' >>"$BOARD"
row7=$(grep '^7	' "$BOARD")
cb set 2 status=blocked
assert "a 7-field row survives an edit to another row byte for byte" '[[ $RC -eq 0 && $(grep "^7	" "$BOARD") == "$row7" ]]'
cb add 9 main "after an unterminated row"
assert "add after a last row without a newline keeps both rows whole" '[[ $RC -eq 0 && $(field 8 7) == "no newline" && $(field 9 2) == open ]]'
cb set 7 status=open
assert "editing a short row writes all 8 fields" '[[ $RC -eq 0 && $(nf 7) -eq 8 && $(field 7 7) == "hand written" ]]'
printf '5\topen\t\tw/5\tmain\t0\tdup\n5\topen\t\tw/5\tmain\t0\tdup\n' >>"$BOARD"
snap
cb set 5 status=done
assert "set refuses an id with two rows" '[[ $RC -ne 0 ]] && unchanged'

echo "show"
cb show
assert "show prints a header and every row" '[[ $RC -eq 0 && $(head -n 1 <<<"$OUT") == $'"'"'id\tstatus\towner\tbranch\tinto\tupdated\tdeliverable\tdeps'"'"' ]] && grep -q "^7	open" <<<"$OUT"'

echo "failed writes"
if ((EUID != 0)); then
  snap
  chmod a-w "$CREW"
  cb add 10 main "cannot write"
  chmod u+w "$CREW"
  assert "a failed write leaves the board unchanged" '[[ $RC -ne 0 ]] && unchanged && ! compgen -G "$CREW/.board.*" >/dev/null'
fi
command rm "$BOARD"
cb add 1 main "fresh"
assert "add creates a missing board" '[[ $RC -eq 0 && $(field 1 2) == open ]]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
