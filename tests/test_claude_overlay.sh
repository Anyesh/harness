#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TOTAL=0

assert() {
    local name="$1"
    TOTAL=$((TOTAL + 1))
    if eval "$2"; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$name"
        FAIL=$((FAIL + 1))
    fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

MARK='!`'

new_home() {
    local home="$1"
    mkdir -p "$home/.cursor" "$home/.local/bin"
    printf 'WIKI_VAULT=%s/vault\n' "$TMP_DIR" > "$home/.harness.env"
    local tool
    for tool in cursor claude codex opencode sb; do
        printf '#!/bin/sh\necho "mock %s"\n' "$tool" > "$home/.local/bin/$tool"
        chmod +x "$home/.local/bin/$tool"
    done
}

# Args: repo root, fake home, then install.sh args. Each home keeps its own
# manifest and backups so the real-repo and fixture-repo runs never share state.
harness_at() {
    local root="$1" home="$2"
    shift 2
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    HARNESS_ENV="$home/.harness.env" \
    HARNESS_MANIFEST="$home/manifest.json" \
    HARNESS_BACKUP_DIR="$home/backups" \
    TMPDIR="$TMP_DIR/tmpdir" \
    PATH="$home/.local/bin:$PATH" \
    bash "$root/install.sh" "$@" 2>&1
}

install_all() {
    local root="$1" home="$2" module
    for module in claude cursor codex opencode; do
        harness_at "$root" "$home" --only "$module" --no-plugins > /dev/null
    done
}

mkdir -p "$TMP_DIR/tmpdir"

echo ""
echo "=== overlay plumbing (fixture repo with a synthetic overlay) ==="
echo ""

FIX="$TMP_DIR/fixture"
mkdir -p "$FIX"
cp -r "$REPO_ROOT/install.sh" "$REPO_ROOT/lib" "$REPO_ROOT/modules" "$REPO_ROOT/configs" "$FIX/"
rm -rf "$FIX/configs/claude-code/commands" "$FIX/configs/claude-code/skills"
mkdir -p "$FIX/configs/claude-code/commands" "$FIX/configs/claude-code/skills/wiki/references"
printf 'overlay commit\n%sdate +%%F`\n' "$MARK" > "$FIX/configs/claude-code/commands/commit.md"
{
    cat "$FIX/configs/shared/skills/wiki/SKILL.md"
    printf '%sdate +%%F`\n' "$MARK"
} > "$FIX/configs/claude-code/skills/wiki/SKILL.md"
printf 'only in overlay\n' > "$FIX/configs/claude-code/skills/wiki/references/extra.md"

FH="$TMP_DIR/fixhome"
new_home "$FH"
install_all "$FIX" "$FH"

assert "fixture: claude command is the overlay file" 'cmp -s "$FIX/configs/claude-code/commands/commit.md" "$FH/.claude/commands/commit.md"'
assert "fixture: claude commands without overlay stay shared" 'cmp -s "$FIX/configs/shared/commands/plan.md" "$FH/.claude/commands/plan.md"'
assert "fixture: cursor command stays shared" 'cmp -s "$FIX/configs/shared/commands/commit.md" "$FH/.cursor/commands/commit.md"'
assert "fixture: opencode command stays shared" 'cmp -s "$FIX/configs/shared/commands/commit.md" "$FH/.config/opencode/commands/commit.md"'
assert "fixture: claude wiki skill has the overlay SKILL.md" 'cmp -s "$FIX/configs/claude-code/skills/wiki/SKILL.md" "$FH/.claude/skills/wiki/SKILL.md"'
assert "fixture: claude wiki skill has overlay-only files" '[[ -f "$FH/.claude/skills/wiki/references/extra.md" ]]'
assert "fixture: agents wiki skill is the shared copy" 'diff -r "$FIX/configs/shared/skills/wiki" "$FH/.agents/skills/wiki" > /dev/null'
assert "fixture: cursor wiki skill is the shared copy" 'diff -r "$FIX/configs/shared/skills/wiki" "$FH/.cursor/skills/wiki" > /dev/null'
assert "fixture: no overlay temp dirs left behind" '[[ -z "$(ls "$TMP_DIR/tmpdir" | grep harness-overlay || true)" ]]'

second=$(install_all "$FIX" "$FH" >/dev/null; harness_at "$FIX" "$FH" --only claude --no-plugins)
assert "fixture: second run skips the overlaid skill" 'grep -qF "skip: skill wiki (unchanged)" <<<"$second"'
assert "fixture: second run skips the overlaid command" 'grep -qF "skip: command commit.md (unchanged)" <<<"$second"'
assert "fixture: second run redeploys nothing" '! grep -qE "skill: wiki|installed: command|updated: command" <<<"$second"'

status_out=$(harness_at "$FIX" "$FH" status) || true
assert "fixture: status is clean" '! grep -qE "DIRTY|MISSING|ORPHAN" <<<"$status_out"'
assert "fixture: overlay command is recorded against its overlay source" 'jq -e --arg f "$FH/.claude/commands/commit.md" ".files[\$f].source == \"configs/claude-code/commands/commit.md\"" "$FH/manifest.json" > /dev/null'

printf 'changed extra\n' > "$FIX/configs/claude-code/skills/wiki/references/extra.md"
third=$(harness_at "$FIX" "$FH" --only claude --no-plugins)
assert "fixture: editing an overlay file redeploys the skill" 'grep -qF "skill: wiki" <<<"$third" && ! grep -qF "skip: skill wiki" <<<"$third"'
assert "fixture: redeployed skill has the new overlay content" 'grep -qF "changed extra" "$FH/.claude/skills/wiki/references/extra.md"'

printf 'changed again\n' > "$FIX/configs/claude-code/skills/wiki/references/extra.md"
DH="$TMP_DIR/dryhome"
new_home "$DH"
dry=$(harness_at "$FIX" "$DH" --only claude --no-plugins --dry-run)
assert "fixture: dry-run reports the overlaid skill" 'grep -qF "[dry-run] would deploy skill: wiki" <<<"$dry"'
assert "fixture: dry-run writes no skill" '[[ ! -e "$DH/.claude/skills/wiki" ]]'
assert "fixture: dry-run leaves no temp dirs" '[[ -z "$(ls "$TMP_DIR/tmpdir" | grep harness-overlay || true)" ]]'

echo ""
echo "=== real overlay content (configs/claude-code) ==="
echo ""

RH="$TMP_DIR/realhome"
new_home "$RH"
install_all "$REPO_ROOT" "$RH"

OV_CMDS="$REPO_ROOT/configs/claude-code/commands"
OV_SKILLS="$REPO_ROOT/configs/claude-code/skills"
SH_CMDS="$REPO_ROOT/configs/shared/commands"
SH_SKILLS="$REPO_ROOT/configs/shared/skills"

overlay_cmds=()
for f in "$OV_CMDS"/*.md; do [[ -f "$f" ]] && overlay_cmds+=("$f"); done
overlay_files=()
while IFS= read -r f; do overlay_files+=("$f"); done < <(find "$OV_SKILLS" -type f 2>/dev/null | sort)

assert "command overlays exist" '[[ ${#overlay_cmds[@]} -gt 0 ]]'
assert "wiki skill overlay exists" '[[ -f "$OV_SKILLS/wiki/SKILL.md" ]]'

cmds_ok=true
for f in "${overlay_cmds[@]}"; do
    name=$(basename "$f")
    grep -qF "$MARK" "$RH/.claude/commands/$name" || cmds_ok=false
    for other in "$RH/.cursor/commands/$name" "$RH/.config/opencode/commands/$name"; do
        if [[ -f "$other" ]] && grep -qF "$MARK" "$other"; then cmds_ok=false; fi
    done
done
assert "claude commands carry the injection marker, cursor and opencode do not" '[[ ${#overlay_cmds[@]} -gt 0 && "$cmds_ok" == true ]]'

plain_ok=true
for f in "$SH_CMDS"/*.md; do
    name=$(basename "$f")
    [[ -f "$RH/.cursor/commands/$name" ]] && ! grep -qF "$MARK" "$RH/.cursor/commands/$name" || plain_ok=false
    [[ -f "$RH/.config/opencode/commands/$name" ]] && ! grep -qF "$MARK" "$RH/.config/opencode/commands/$name" || plain_ok=false
done
assert "no cursor or opencode command contains the marker" '[[ "$plain_ok" == true ]]'

assert "claude wiki skill is the overlay SKILL.md" 'cmp -s "$OV_SKILLS/wiki/SKILL.md" "$RH/.claude/skills/wiki/SKILL.md"'
assert "agents wiki SKILL.md is byte-equal to shared" 'cmp -s "$SH_SKILLS/wiki/SKILL.md" "$RH/.agents/skills/wiki/SKILL.md"'
assert "agents wiki skill has no marker" '! grep -rqF "$MARK" "$RH/.agents/skills/wiki"'

real_second=$(harness_at "$REPO_ROOT" "$RH" --only claude --no-plugins)
assert "second run prints skip: skill wiki (unchanged)" 'grep -qF "skip: skill wiki (unchanged)" <<<"$real_second"'
real_status=$(harness_at "$REPO_ROOT" "$RH" status) || true
assert "status is clean after the overlay deploy" '! grep -qE "DIRTY|MISSING|ORPHAN" <<<"$real_status"'
assert "no overlay temp dirs left behind" '[[ -z "$(ls "$TMP_DIR/tmpdir" | grep harness-overlay || true)" ]]'

pairs_ok=true
for f in "${overlay_cmds[@]}"; do
    [[ -f "$SH_CMDS/$(basename "$f")" ]] || pairs_ok=false
done
for f in "${overlay_files[@]}"; do
    rel=${f#"$OV_SKILLS"/}
    [[ -d "$SH_SKILLS/${rel%%/*}" ]] || pairs_ok=false
    [[ "${rel#*/}" != SKILL.md || -f "$SH_SKILLS/$rel" ]] || pairs_ok=false
done
assert "every overlay command, skill dir and SKILL.md has a shared counterpart" '[[ "$pairs_ok" == true ]]'

strip_wiki_overlay() {
    awk '
        NR == 1 && $0 == "---" { fm = 1; print; next }
        fm && $0 == "---" { fm = 0; skip = 0; print; next }
        fm && /^(arguments|allowed-tools):/ { skip = 1; next }
        fm && skip && /^([[:space:]]|-)/ { next }
        { skip = 0 }
        index($0, "!`") == 1 { next }
        /^Host note:/ { next }
        { print }
    ' "$1"
}
assert "wiki overlay differs from shared only by injection lines, host note and two frontmatter keys" \
    '[[ -f "$OV_SKILLS/wiki/SKILL.md" ]] && diff -B <(strip_wiki_overlay "$OV_SKILLS/wiki/SKILL.md") "$SH_SKILLS/wiki/SKILL.md" > /dev/null'
assert "wiki overlay has exactly one Host note line" '[[ -f "$OV_SKILLS/wiki/SKILL.md" && "$(grep -c "^Host note:" "$OV_SKILLS/wiki/SKILL.md")" == 1 ]]'

FIXREPO="$TMP_DIR/repo"
mkdir -p "$TMP_DIR/vault/wiki"
git -C "$TMP_DIR" init -q repo
git -C "$FIXREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'x\n' > "$FIXREPO/file.txt"
git -C "$FIXREPO" add file.txt

frontmatter() { awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { exit } f { print }' "$1"; }

lint_ok=true
lint_ran=0
lint_files=("${overlay_cmds[@]}")
[[ -f "$OV_SKILLS/wiki/SKILL.md" ]] && lint_files+=("$OV_SKILLS/wiki/SKILL.md")
for f in "${lint_files[@]}"; do
    allowed=$(frontmatter "$f" | grep -E '^allowed-tools:|^[[:space:]]+-' || true)
    skill_dir=$(dirname "$f")
    while IFS= read -r inj; do
        [[ -z "$inj" ]] && continue
        lint_ran=$((lint_ran + 1))
        bin=${inj%% *}
        grep -qF "Bash($bin" <<<"$allowed" || { echo "    not allowed in $(basename "$f"): $bin"; lint_ok=false; }
        run=${inj//'${CLAUDE_SKILL_DIR}'/$RH/.claude/skills/$(basename "$skill_dir")}
        run=${run//'$ARGUMENTS'/status}
        run=${run//'$operation'/status}
        run=${run//'$0'/status}
        (cd "$FIXREPO" && HOME="$RH" WIKI_VAULT="$TMP_DIR/vault" bash -c "$run" > /dev/null 2>&1) || { echo "    non-zero exit in $(basename "$f"): $inj"; lint_ok=false; }
    done < <(grep -oE '!`[^`]+`' "$f" | sed -E 's/^!`//; s/`$//')
done
assert "injections exist to lint" '[[ $lint_ran -gt 0 ]]'
assert "each injected binary is in allowed-tools and each injection exits 0" '[[ $lint_ran -gt 0 && "$lint_ok" == true ]]'

echo ""
echo "Claude overlay: $TOTAL total, $PASS passed, $FAIL failed"

[[ $FAIL -eq 0 ]]
