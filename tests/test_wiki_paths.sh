#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$REPO_ROOT/configs/shared/hooks"

PASS=0
FAIL=0

check() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s (want %q, got %q)\n' "$name" "$want" "$got"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

in_env() {
  env -i HOME="$TMP_DIR/home" PATH="$PATH" HARNESS_ENV="$TMP_DIR/harness.env" "$@" bash -c "
    set -uo pipefail
    source '$HOOKS/load-harness-env.sh'
    source '$HOOKS/harness-project.sh'
    $(cat)
  "
}

mkdir -p "$TMP_DIR/home"
git -C "$TMP_DIR" init -q My_Repo
git -C "$TMP_DIR/My_Repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMP_DIR/My_Repo" worktree add -q "$TMP_DIR/w-t8-seed-1b57" -b wt
git init -q --bare "$TMP_DIR/incr.git"
mkdir -p "$TMP_DIR/plain dir"

echo ""
check "main checkout slug" "my-repo" \
  "$(in_env <<<"harness_wiki_slug '$TMP_DIR/My_Repo'")"
check "worktree resolves to its main checkout" "my-repo" \
  "$(in_env <<<"harness_wiki_slug '$TMP_DIR/w-t8-seed-1b57'")"
check "bare repo drops the .git suffix" "incr" \
  "$(in_env <<<"harness_wiki_slug '$TMP_DIR/incr.git'")"
check "outside git falls back to the folder name" "plain-dir" \
  "$(in_env <<<"harness_wiki_slug '$TMP_DIR/plain dir'")"
check "project slug keeps the worktree name for handoffs" "w-t8-seed-1b57" \
  "$(in_env <<<"harness_project_slug '$TMP_DIR/w-t8-seed-1b57'")"

check "work vault appends Work/agent-wiki" "/v/Work/agent-wiki" \
  "$(in_env <<<"harness_work_vault /v/")"
check "work vault mapping is idempotent" "/v/Work/agent-wiki" \
  "$(in_env <<<"harness_work_vault /v/Work/agent-wiki")"

printf 'WIKI_VAULT=/v\nHARNESS_WORK=1\n' >"$TMP_DIR/harness.env"
check "work machine maps the vault from the env file" "/v/Work/agent-wiki" \
  "$(in_env <<<'load_wiki_vault; printf %s "$WIKI_VAULT"')"
check "explicit personal settings env wins on a work machine" "/v" \
  "$(in_env WIKI_VAULT=/v HARNESS_WORK=0 <<<'load_wiki_vault; printf %s "$WIKI_VAULT"')"
check "work settings env is not mapped twice" "/v/Work/agent-wiki" \
  "$(in_env WIKI_VAULT=/v/Work/agent-wiki HARNESS_WORK=1 <<<'load_wiki_vault; printf %s "$WIKI_VAULT"')"

printf 'WIKI_VAULT=/v\n' >"$TMP_DIR/harness.env"
check "personal machine keeps the personal vault" "/v" \
  "$(in_env <<<'load_wiki_vault; printf %s "$WIKI_VAULT"')"
mkdir -p "$TMP_DIR/v2/Work/agent-wiki/wiki/projects/harness"
printf 'WIKI_VAULT=%s\n' "$TMP_DIR/v2" >"$TMP_DIR/harness.env"
check "a work-vault folder never makes a personal session work" "$TMP_DIR/v2" \
  "$(in_env <<<'load_wiki_vault; printf %s "$WIKI_VAULT"')"
: >"$TMP_DIR/harness.env"
check "no vault configured resolves empty" "" \
  "$(in_env <<<'load_wiki_vault; printf %s "${WIKI_VAULT:-}"')"

mkdir -p "$TMP_DIR/home/.claude"
ln -s "$HOOKS" "$TMP_DIR/home/.claude/hooks"
CMD_CTX="$REPO_ROOT/configs/claude-code/scripts/cmd-context.sh"
WIKI_OP="$REPO_ROOT/configs/claude-code/skills/wiki/scripts/wiki-op.sh"
ctx() {
  (cd "$1" && env -i HOME="$TMP_DIR/home" PATH="$PATH" HARNESS_ENV="$TMP_DIR/harness.env" bash "${@:2}")
}
mkdir -p "$TMP_DIR/v3/wiki/projects/my-repo" "$TMP_DIR/v3/Work/agent-wiki/wiki/projects/my-repo"
printf 'WIKI_VAULT=%s\n' "$TMP_DIR/v3" >"$TMP_DIR/harness.env"
check "cmd-context gives a worktree its main checkout's slug" "repo_slug: my-repo" \
  "$(ctx "$TMP_DIR/w-t8-seed-1b57" "$CMD_CTX" devlog | grep '^repo_slug:')"
check "cmd-context reports the project index, not the top index" "project_index: absent" \
  "$(ctx "$TMP_DIR/My_Repo" "$CMD_CTX" devlog | grep -E '^(project_index|wiki_index):')"
check "wiki-op gives a worktree its main checkout's slug" "project_slug: my-repo" \
  "$(ctx "$TMP_DIR/w-t8-seed-1b57" "$WIKI_OP" log | grep '^project_slug:')"
printf 'WIKI_VAULT=%s\nWIKI_WORK_PROJECTS=my-repo\n' "$TMP_DIR/v3" >"$TMP_DIR/harness.env"
check "cmd-context keeps a once-listed work slug in the personal vault" "wiki_vault: $TMP_DIR/v3" \
  "$(ctx "$TMP_DIR/My_Repo" "$CMD_CTX" devlog | grep '^wiki_vault:')"
printf 'WIKI_VAULT=%s\nHARNESS_WORK=1\n' "$TMP_DIR/v3" >"$TMP_DIR/harness.env"
check "cmd-context on a work machine uses the work vault" "wiki_vault: $TMP_DIR/v3/Work/agent-wiki" \
  "$(ctx "$TMP_DIR/My_Repo" "$CMD_CTX" devlog | grep '^wiki_vault:')"
check "wiki-op on a work machine uses the work vault" "vault: $TMP_DIR/v3/Work/agent-wiki" \
  "$(ctx "$TMP_DIR/My_Repo" "$WIKI_OP" log | grep '^vault:')"
printf '%s\n' "$TMP_DIR/v3" >"$TMP_DIR/My_Repo/.wiki-vault"
check "wiki-op ignores a .wiki-vault outside the vault in use" "vault: $TMP_DIR/v3/Work/agent-wiki" \
  "$(ctx "$TMP_DIR/My_Repo" "$WIKI_OP" log | grep '^vault:')"
printf '%s\n' "$TMP_DIR/v3/Work/agent-wiki/sub" >"$TMP_DIR/My_Repo/.wiki-vault"
check "wiki-op honours a .wiki-vault inside the vault in use" "vault: $TMP_DIR/v3/Work/agent-wiki/sub" \
  "$(ctx "$TMP_DIR/My_Repo" "$WIKI_OP" log | grep '^vault:')"
rm -f "$TMP_DIR/My_Repo/.wiki-vault"

echo ""
echo "wiki-paths: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
