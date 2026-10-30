#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export HARNESS_BLOCK_LOG=/dev/null

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
    FAIL=$((FAIL + 1))
  fi
}

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "SKIP: gitleaks not installed"
  exit 0
fi

export LEAKGUARD_CONFIG="$REPO_ROOT/configs/leakguard/gitleaks.toml"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REAL_GITLEAKS="$(command -v gitleaks)"
H="$TMP/home"
mkdir -p "$H/bin"
printf '#!/bin/sh\necho x >>"%s/gitleaks.calls"\nexec "%s" "$@"\n' "$H" "$REAL_GITLEAKS" >"$H/bin/gitleaks"
chmod +x "$H/bin/gitleaks"
printf 'LEAKGUARD_PERSONAL=zorblax,@example.com\n' >"$H/.harness.env"

install_leakguard() {
  local home="$1"
  env -u LEAKGUARD_CONFIG -u LEAKGUARD_PERSONAL HOME="$home" HARNESS_ENV="$home/.harness.env" \
    XDG_CONFIG_HOME="$home/.config" PATH="$H/bin:$PATH" REPO_ROOT="$REPO_ROOT" DRY_RUN=false bash -c '
      source "$REPO_ROOT/lib/common.sh"
      source "$REPO_ROOT/lib/profile.sh"
      source "$REPO_ROOT/modules/leakguard.sh"
      leakguard_install' 2>&1
}

g() {
  env -u LEAKGUARD_CONFIG HOME="$H" XDG_CONFIG_HOME="$H/.config" GIT_CONFIG_NOSYSTEM=1 \
    PATH="$H/bin:$PATH" git "$@"
}

new_repo() {
  g init -q "$1"
  g -C "$1" config user.email t@t
  g -C "$1" config user.name t
}

# Stages one file and reports whether the commit was accepted.
try_commit() {
  local repo="$1" text="$2"
  rm -f "$repo/staged.txt"
  g -C "$repo" reset -q 2>/dev/null || true
  echo "$text" >"$repo/staged.txt"
  g -C "$repo" add staged.txt
  g -C "$repo" commit -q -m x >/dev/null 2>&1
}

install_leakguard "$H" >/dev/null
assert "installed config carries the personal terms from the env file" \
  "grep -q zorblax '$H/.config/leakguard/gitleaks.toml'"
assert "repo ruleset names no personal term" \
  "! grep -qi zorblax '$REPO_ROOT/configs/leakguard/gitleaks.toml'"

chmod 644 "$H/.config/leakguard/gitleaks.toml"
install_leakguard "$H" >/dev/null
assert "the installed ruleset is private to the user" \
  "[ \"\$(stat -c %a '$H/.config/leakguard/gitleaks.toml' 2>/dev/null || stat -f %Lp '$H/.config/leakguard/gitleaks.toml')\" = 600 ]"
assert "reinstall registers the scan hook once" \
  "[ \"\$(g config --global --get-all hook.leakguard.command | wc -l)\" -eq 1 ]"

env -u LEAKGUARD_PERSONAL REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/lib/common.sh"
  source "$REPO_ROOT/modules/leakguard.sh"
  leakguard_render_config "$REPO_ROOT/configs/leakguard/gitleaks.toml" " my box ,a\"b\\c"' >"$TMP/full.toml"
assert "a term keeps its inner space" "grep -q 'my box' '$TMP/full.toml'"
assert "terms with quotes and backslashes render a valid ruleset" \
  "echo 'the a\"b\\c host' | gitleaks stdin --no-banner -c '$TMP/full.toml' -f json -r '$TMP/terms.json' >/dev/null 2>&1; [ \"\$(jq length '$TMP/terms.json' 2>/dev/null)\" = 1 ]"

OLDGIT="$TMP/oldgit"
mkdir -p "$OLDGIT/bin"
cat >"$OLDGIT/bin/git" <<EOF
#!/usr/bin/env bash
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    -c) case "\$2" in hook.*) shift 2; continue ;; esac ;;
    config) case " \$* " in *" hook."*) exit 0 ;; esac ;;
  esac
  args+=("\$1"); shift
done
exec "$(command -v git)" "\${args[@]}"
EOF
chmod +x "$OLDGIT/bin/git"
: >"$OLDGIT/.harness.env"
OLD_RC=0
OLD_OUT="$(PATH="$OLDGIT/bin:$PATH" install_leakguard "$OLDGIT")" || OLD_RC=$?
assert "install fails on a git without config hooks" "[ $OLD_RC -ne 0 ] && [[ \"\$OLD_OUT\" == *'config hooks'* ]]"

UNSET="$TMP/unset-home"
mkdir -p "$UNSET"
: >"$UNSET/.harness.env"
UNSET_OUT="$(install_leakguard "$UNSET")"
assert "install without personal terms warns" "[[ \"\$UNSET_OUT\" == *LEAKGUARD_PERSONAL* ]]"

REPO="$TMP/repo"
new_repo "$REPO"
assert "blocks a personal term" "! try_commit '$REPO' 'the box is Zorblax'"
assert "blocks a personal email" "! try_commit '$REPO' 'mail a.b@example.com'"
assert "blocks a 10.x address" "! try_commit '$REPO' 'url http://10.1.2.3:8080'"
assert "blocks a 172.16/12 address" "! try_commit '$REPO' 'host 172.20.1.1'"
assert "blocks a 192.168 address" "! try_commit '$REPO' 'host 192.168.1.9'"
assert "blocks a tailnet address" "! try_commit '$REPO' 'peer 100.101.5.6'"
assert "blocks a machine-local path" "! try_commit '$REPO' 'cd /mnt/data/projects'"
assert "passes a version number and a public address" \
  "try_commit '$REPO' 'node 10.0.0, python 3.12.1, dns 1.1.1.1, 172.15.0.1'"

: >"$H/gitleaks.calls"
try_commit "$REPO" "hello"
assert "a commit is scanned exactly once" "[ \"\$(wc -l <'$H/gitleaks.calls')\" -eq 1 ]"

assert "LEAKGUARD_SKIP bypasses" "LEAKGUARD_SKIP=1 try_commit '$REPO' 'the box is zorblax'"

printf '#!/bin/sh\ntouch "%s/local_ran"\nexit 0\n' "$TMP" >"$REPO/.git/hooks/pre-commit"
chmod +x "$REPO/.git/hooks/pre-commit"
try_commit "$REPO" "more"
assert "dispatcher chains repo-local hook" "[ -f '$TMP/local_ran' ]"

OWN="$TMP/own-hookspath"
new_repo "$OWN"
mkdir -p "$OWN/.myhooks"
printf '#!/bin/sh\ntouch "%s/own_ran"\nexit 0\n' "$TMP" >"$OWN/.myhooks/pre-commit"
chmod +x "$OWN/.myhooks/pre-commit"
g -C "$OWN" config core.hooksPath .myhooks
assert "blocks a leak in a repo with its own hooksPath" "! try_commit '$OWN' 'the box is zorblax'"
assert "passes a clean change in a repo with its own hooksPath" "try_commit '$OWN' 'hello'"
assert "the repo's own hook still runs" "[ -f '$TMP/own_ran' ]"

PUB="$TMP/pub"
mkdir -p "$PUB/dist" "$PUB/pkg"
echo "secrets under /mnt/data/keys" > "$PUB/pkg/bad.txt"
tar -czf "$PUB/dist/pkg-0.1.tar.gz" -C "$PUB" pkg
GUARD="$REPO_ROOT/configs/shared/hooks/publish-leak-guard.sh"
assert "publish guard blocks poisoned sdist" \
  "! echo '{\"tool_input\":{\"command\":\"cd $PUB && uv publish\"},\"cwd\":\"/\"}' | bash '$GUARD' >/dev/null 2>&1"

CLEANPUB="$TMP/cleanpub"
mkdir -p "$CLEANPUB/dist" "$CLEANPUB/pkg"
echo "nothing personal" > "$CLEANPUB/pkg/ok.txt"
tar -czf "$CLEANPUB/dist/pkg-0.1.tar.gz" -C "$CLEANPUB" pkg
assert "publish guard passes clean sdist" \
  "echo '{\"tool_input\":{\"command\":\"cd $CLEANPUB && uv publish\"},\"cwd\":\"/\"}' | bash '$GUARD' >/dev/null 2>&1"

assert "publish guard ignores non-publish commands" \
  "echo '{\"tool_input\":{\"command\":\"ls -la\"},\"cwd\":\"$PUB\"}' | bash '$GUARD' >/dev/null 2>&1"

echo x > "$PUB/pkg/.scope.md"
tar -czf "$PUB/dist/pkg-0.2.tar.gz" -C "$PUB" pkg
assert "publish guard blocks forbidden filenames" \
  "! echo '{\"tool_input\":{\"command\":\"cd $PUB && twine upload dist/*\"},\"cwd\":\"/\"}' | bash '$GUARD' >/dev/null 2>&1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
