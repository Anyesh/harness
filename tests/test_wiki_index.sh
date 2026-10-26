#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$REPO_ROOT/configs/shared/hooks/wiki-index-build.sh"

PASS=0
FAIL=0

assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
export XDG_STATE_HOME="$TMP_DIR/state"

V="$TMP_DIR/vault"
W="$V/wiki"
build() { bash "$BUILD" "$@"; }

echo ""

mkdir -p "$W/projects/alpha/plans" "$W/projects/beta" "$W/projects/gamma" "$W/concepts"
printf '## Projects\n\n### alpha: hand built\n' >"$W/index.md"
build "$V"
assert "a hand-built index without the marker is never replaced" \
  'grep -q "hand built" "$W/index.md"'

rm "$W/index.md"
cat >"$W/projects/alpha/index.md" <<'EOF'
---
type: project-index
project: alpha
title: Alpha app
---

# Alpha app

- [Devlog](devlog.md): chronological project log
- [Plan](plans/p.md): the plan
  - [Sub](plans/sub.md): nested
- [Beta link](../beta/devlog.md): cross-project
- [[alpha-concept]]: wikilink stays
- [Site](https://example.com/x.md): url stays
- [Spaced](plans/My%20Page.md): encoded space
- [Angle](<plans/Angle Page.md>): angle brackets
- [[kuzu]]: bare wikilink
- [[plans/wiki-page|Wiki page]]: aliased wikilink
- [Rooted](projects/alpha/plans/rooted.md): written relative to wiki/
EOF
printf '# Rooted\n' >"$W/projects/alpha/plans/rooted.md"
printf -- '- [[devlog]]: bare devlog wikilink\n' >>"$W/projects/alpha/index.md"
mkdir -p "$W/projects/alpha/worktrees/w1"
printf '# W1 devlog\n' >"$W/projects/alpha/worktrees/w1/devlog.md"
printf '# Loose project page\n' >"$W/projects/loose.md"
printf '# Activity Log\n' >"$W/log.md"
mkdir -p "$W/misc"
printf '# Loose note\n' >"$W/misc/note.md"
for page in "My Page" "Angle Page" kuzu wiki-page; do printf '# %s\n' "$page" >"$W/projects/alpha/plans/$page.md"; done
printf '# Devlog\n' >"$W/projects/alpha/devlog.md"
printf '# Plan\n' >"$W/projects/alpha/plans/p.md"
printf '# Sub\n' >"$W/projects/alpha/plans/sub.md"
printf -- '---\ntitle: Forgotten page\n---\n# Other\n' >"$W/projects/alpha/plans/forgotten.md"
printf '# Beta devlog\n' >"$W/projects/beta/devlog.md"
printf -- '---\ntype: project-index\nproject: concepts\n---\n\n- [Idea](idea.md): an idea\n' >"$W/concepts/index.md"
printf '# Idea\n' >"$W/concepts/idea.md"
build "$V"
OUT=$(cat "$W/index.md")
assert "a missing index is generated with the marker" 'grep -q "^generated: true" <<<"$OUT"'
assert "project section uses the folder index title" 'grep -q "^### alpha: Alpha app$" <<<"$OUT"'
assert "links are rewritten relative to wiki/" 'grep -qF "[Plan](projects/alpha/plans/p.md)" <<<"$OUT"'
assert "sub-bullets keep their indent" 'grep -qF "  - [Sub](projects/alpha/plans/sub.md)" <<<"$OUT"'
assert "cross-project links resolve" 'grep -qF "[Beta link](projects/beta/devlog.md)" <<<"$OUT"'
assert "wikilinks pass through" 'grep -qF "[[alpha-concept]]" <<<"$OUT"'
assert "urls pass through" 'grep -qF "(https://example.com/x.md)" <<<"$OUT"'
assert "pages missing from the folder index are listed as unlisted" \
  'grep -qF "[Forgotten page](projects/alpha/plans/forgotten.md): unlisted" <<<"$OUT"'
assert "encoded, angle-bracket and wikilink entries count as listed" \
  '! grep -E "(My Page|Angle Page|kuzu|wiki-page)\.md\): unlisted" <<<"$OUT"'
assert "angle-bracket links are rewritten relative to wiki/" \
  'grep -qF "[Angle](<projects/alpha/plans/Angle Page.md>)" <<<"$OUT"'
assert "a link written relative to wiki/ resolves instead of doubling the folder" \
  'grep -qF "[Rooted](projects/alpha/plans/rooted.md)" <<<"$OUT" && ! grep -q "rooted.md): unlisted" <<<"$OUT"'
assert "pages outside the indexed folders are still listed" \
  'grep -qF "[Activity Log](log.md)" <<<"$OUT" && grep -qF "[Loose note](misc/note.md)" <<<"$OUT"'
assert "the generated index does not list itself" '! grep -qF "](index.md)" <<<"$OUT"'
assert "a resolvable wikilink is rewritten to its path from wiki/" \
  'grep -qF "[[projects/alpha/plans/wiki-page|Wiki page]]" <<<"$OUT"'
assert "a bare wikilink lists only the page it resolves to" \
  'grep -qF "(projects/alpha/worktrees/w1/devlog.md): unlisted" <<<"$OUT"'
assert "a loose file directly under projects/ is still listed" 'grep -qF "(projects/loose.md)" <<<"$OUT"'
assert "a folder without an index gets a stub with its pages" \
  'grep -q "^### beta$" <<<"$OUT" && grep -qF "(projects/beta/devlog.md)" <<<"$OUT"'
assert "an empty folder still gets a heading" 'grep -q "^### gamma$" <<<"$OUT"'
assert "concepts come from their own index" 'grep -qF "[Idea](concepts/idea.md)" <<<"$OUT"'
assert "concepts sit under the Concepts heading" \
  '[ "$(grep -n "^## Concepts" <<<"$OUT" | cut -d: -f1)" -lt "$(grep -n "concepts/idea.md" <<<"$OUT" | cut -d: -f1)" ]'
assert "no section heading is repeated" \
  '[ -z "$(grep "^###" <<<"$OUT" | sort | uniq -d)" ]'

BEFORE=$(stat -c %Y "$W/index.md")
touch -d '2001-01-01' "$W/index.md"
build "$V"
assert "an unchanged index is not rewritten" '[ "$(stat -c %Y "$W/index.md")" = "$(date -d 2001-01-01 +%s)" ]'

printf '# New\n' >"$W/projects/beta/new.md"
build "$V" --if-changed
assert "if-changed rebuilds after a page changes" 'grep -qF "projects/beta/new.md" "$W/index.md"'
cp "$W/index.md" "$TMP_DIR/snapshot"
rm -f "$W/projects/beta/new.md"
touch -d '2001-01-01' "$W/projects/beta"
find "$W" -name '*.md' -exec touch -d '2001-01-01' {} +
build "$V" --if-changed
assert "if-changed skips when no page is newer than the last run" 'cmp -s "$W/index.md" "$TMP_DIR/snapshot"'

mkdir -p "$TMP_DIR/novault"
build "$TMP_DIR/novault"
assert "a vault without wiki/ gets nothing created" '[ ! -e "$TMP_DIR/novault/wiki" ]'
(cd "$TMP_DIR" && build "relative")
assert "a relative vault path is refused" '[ ! -e "$TMP_DIR/relative" ]'
build ""
assert "an empty vault argument exits cleanly" 'true'

echo ""
echo "wiki-index: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
