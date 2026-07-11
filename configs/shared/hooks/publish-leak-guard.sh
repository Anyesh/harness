#!/bin/bash
# PreToolUse guard for publish commands: scans the built artifacts a publish
# would upload, because build backends pack untracked files that no
# pre-commit hook ever sees. Blocks (exit 2) when an artifact contains
# personal info or secrets per the leakguard gitleaks config.
set -uo pipefail

input=$(cat)
command=$(echo "$input" | jq -r '.command // .tool_input.command // empty')
[ -z "$command" ] && exit 0

if ! echo "$command" | grep -qE '(uv publish|twine upload|hatch publish|flit publish|python3? -m twine|cargo publish)'; then
  exit 0
fi

cwd=$(echo "$input" | jq -r '.cwd // empty')
# The publish often arrives as "cd /repo && uv publish"; the artifacts live
# under the cd target, not the session cwd, so scan both.
cd_target=$(echo "$command" | grep -oE '(^|&&|;)[[:space:]]*cd[[:space:]]+[^;&|]+' | head -1 |
  sed -E 's/^(&&|;)?[[:space:]]*cd[[:space:]]+//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//')

cfg="${LEAKGUARD_CONFIG:-$HOME/.config/leakguard/gitleaks.toml}"
command -v gitleaks >/dev/null 2>&1 || exit 0

# Names that should never ship regardless of content.
bad_names='(^|/)(\.scope\.md|\.env(\..+)?|\.pypirc|\.netrc|id_rsa|id_ed25519|.*\.pem|.*\.key)$'

artifacts=""
for dir in "$cd_target" "$cwd" "."; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  for f in "$dir"/dist/*.tar.gz "$dir"/dist/*.whl "$dir"/dist/*.zip "$dir"/target/package/*.crate; do
    [ -e "$f" ] && artifacts+="$f"$'\n'
  done
done
artifacts=$(echo "$artifacts" | sort -u | grep -v '^$')

findings=""
while IFS= read -r f; do
  [ -n "$f" ] || continue

  case "$f" in
    *.tar.gz | *.crate) names=$(tar -tzf "$f" 2>/dev/null) ;;
    *) names=$(unzip -Z1 "$f" 2>/dev/null) ;;
  esac
  bad=$(echo "$names" | grep -E "$bad_names" || true)
  [ -n "$bad" ] && findings+="$f packs files that must not ship:"$'\n'"$bad"$'\n'

  case "$f" in
    *.tar.gz | *.crate) content=$(tar -xzOf "$f" 2>/dev/null | head -c 5000000) ;;
    *) content=$(unzip -p "$f" 2>/dev/null | head -c 5000000) ;;
  esac
  hits=$(printf '%s' "$content" | gitleaks stdin --no-banner --redact -c "$cfg" 2>&1)
  [ $? -ne 0 ] && findings+="$f content:"$'\n'"$(echo "$hits" | head -15)"$'\n'
done <<<"$artifacts"

if [ -n "$findings" ]; then
  {
    echo "publish-leak-guard: BLOCKED. Built artifacts contain personal info, secrets,"
    echo "or files that must not ship. Do not publish; fix and rebuild first."
    echo "Build backends pack untracked files, so check .gitignore covers the finding."
    echo ""
    echo "$findings" | head -40
  } >&2
  exit 2
fi
exit 0
