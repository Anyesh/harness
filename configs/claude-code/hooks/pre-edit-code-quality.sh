#!/bin/bash
# Global PreToolUse hook: Enforces universal code quality rules
# Blocks: emojis, inline imports (Python), unnecessary docstrings (Python),
#         obvious comments (JS/TS), empty catch blocks (JS/TS), swallowed exceptions (Python)

INPUT=$(cat)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# Markdown exempt entirely: handovers/notes/READMEs use scannable short lines by design
case "$FILE_PATH" in
    *.md|*.mdx) exit 0 ;;
esac

# Prose files: check for staccato style
case "$FILE_PATH" in
    *.txt|*.html)
        CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null) || exit 0
        if [ -n "$CONTENT" ]; then
            # HTML is markup, not prose: tags, attribute values (initial-scale=1.0),
            # and script/style bodies contain dots that the sentence splitter would
            # otherwise miscount as staccato sentences. Strip comments, script/style
            # blocks, and all tags first so only visible text nodes reach the check.
            case "$FILE_PATH" in
                *.html)
                    CONTENT=$(printf '%s' "$CONTENT" | perl -0777 -pe '
                        s/<!--.*?-->//gs;
                        s/<script\b[^>]*>.*?<\/script>//gsi;
                        s/<style\b[^>]*>.*?<\/style>//gsi;
                        s/<[^>]*>/ /gs;
                    ')
                    ;;
            esac
            # Strip markdown structure before checking prose: frontmatter, headers, bullets,
            # numbered lists, code blocks, tables, wikilinks-only lines, blank lines, and
            # lines that are entirely bold/italic markers so that only actual prose paragraphs
            # are evaluated for staccato patterns.
            STACCATO=$(printf '%s' "$CONTENT" | awk '
                /^---/       { in_fm = !in_fm; next }
                in_fm        { next }
                /^```/       { in_code = !in_code; next }
                in_code      { next }
                /^[[:space:]]*$/              { next }
                /^[[:space:]]*#/             { next }
                /^[[:space:]]*[-*+] /        { next }
                /^[[:space:]]*[0-9]+\. /     { next }
                /^[[:space:]]*\|/            { next }
                /^[[:space:]]*>/             { next }
                /^[[:space:]]*\[\[/          { next }
                /^[[:space:]]*\*\*/          { next }
                /^[[:space:]]*!/             { next }
                { print }
            ' | grep -oE '[^.!?]*[.!?]' | awk '
                { gsub(/^[[:space:]]+/,"") }
                NF <= 6 { c++; next }
                { if (c >= 5) { print c " consecutive short sentences"; exit } c = 0 }
                END { if (c >= 5) print c " consecutive short sentences" }
            ' | head -1 || true)
            if [ -n "$STACCATO" ]; then
                cat >&2 <<EOF
[hook:global] BLOCKED: Staccato writing style detected ($STACCATO)
Rule: Write in natural, flowing prose. Connect related ideas with conjunctions, commas, and semicolons.
File: $FILE_PATH

Bad: "X does Y. Z handles W. A calls B. C returns D."
Good: "X does Y while Z handles W, and when A calls B it returns D."

Rewrite with connected, flowing sentences.
EOF
                exit 2
            fi
        fi
        exit 0
        ;;
esac

# Only check source files
case "$FILE_PATH" in
    *.py|*.ts|*.tsx|*.js|*.jsx) ;;
    *) exit 0 ;;
esac

IS_TEST=false
case "$FILE_PATH" in
    *test*|*spec*|*conftest*) IS_TEST=true ;;
esac

CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null) || exit 0

if [ -z "$CONTENT" ]; then
    exit 0
fi

# Check 1: No emoji characters in source code
FOUND=$(echo "$CONTENT" | grep -Pn '[\x{1F300}-\x{1F9FF}\x{2600}-\x{26FF}\x{2700}-\x{27BF}\x{1F600}-\x{1F64F}\x{1F680}-\x{1F6FF}\x{1FA00}-\x{1FA6F}\x{1FA70}-\x{1FAFF}]' 2>/dev/null | head -3 || true)
if [ -n "$FOUND" ]; then
    cat >&2 <<EOF
[hook:global] BLOCKED: Emoji characters in source code
Rule: No emojis in source files. Use text labels or icon components instead.
File: $FILE_PATH

Violations found:
$FOUND
EOF
    exit 2
fi

# Python-specific checks
case "$FILE_PATH" in
    *.py)
        # Check 2: No inline imports (import inside function bodies) — skip tests
        if [ "$IS_TEST" = false ]; then
            FOUND=$(echo "$CONTENT" | awk '
                /^[[:space:]]*if[[:space:]]+TYPE_CHECKING[[:space:]]*:/ { in_tc=1; next }
                in_tc && /^[[:space:]]*$/ { next }
                in_tc && !/^[[:space:]]/ { in_tc=0 }
                in_tc { next }
                /^[[:space:]]{4,}(import[[:space:]]|from[[:space:]]+[^[:space:]]+[[:space:]]+import[[:space:]])/ { print NR": "$0 }
            ' | grep -vE '# noqa|# type:|TYPE_CHECKING' | head -3 || true)
            if [ -n "$FOUND" ]; then
                cat >&2 <<EOF
[hook:global] BLOCKED: Inline import detected (import inside function/method body)
Rule: All imports must be at the top of the file. Only exception: genuine circular dependency with a comment explaining why.
File: $FILE_PATH

Violations found:
$FOUND

Move the import to the top of the file.
EOF
                exit 2
            fi
        fi

        # Check 3: Unnecessary one-liner docstrings
        FOUND=$(echo "$CONTENT" | grep -nE '"""[^"]{5,80}"""\s*$' | head -3 || true)
        if [ -n "$FOUND" ]; then
            cat >&2 <<EOF
[hook:global] BLOCKED: Unnecessary one-liner docstring detected
Rule: NO unnecessary one-liner docstrings. Code should be self-documenting.
File: $FILE_PATH

Violations found:
$FOUND

Only add comments when the logic is non-obvious or there's important context that can't be expressed in code.
EOF
            exit 2
        fi

        # Check 4: Broad except with pass/ellipsis (swallowed errors)
        FOUND=$(echo "$CONTENT" | grep -PzoA1 'except\s+(Exception|BaseException)\s*:\s*\n\s*(pass|\.\.\.)\s*$' 2>/dev/null | head -3 || true)
        if [ -n "$FOUND" ]; then
            cat >&2 <<EOF
[hook:global] BLOCKED: Swallowed exception (broad except with pass/...)
Rule: Do not catch broad exceptions just to ignore them.
File: $FILE_PATH

Catch specific exceptions, or log and re-raise.
EOF
            exit 2
        fi
        ;;

    *.ts|*.tsx|*.js|*.jsx)
        # Check 5: Unnecessary obvious comments in JS/TS
        FOUND=$(echo "$CONTENT" | grep -nE '^\s*//\s*(Get|Set|Return|Create|Update|Delete|Check|Handle|Process|Initialize|Configure|Validate|Fetch|Load|Save|Send|Parse|Convert|Format|Build|Render|Display|Calculate|Compute)\s' | head -3 || true)
        if [ -n "$FOUND" ]; then
            cat >&2 <<EOF
[hook:global] BLOCKED: Unnecessary obvious comment detected
Rule: NO obvious comments. Code should be self-documenting.
File: $FILE_PATH

Violations found:
$FOUND

Only add comments when the logic is non-obvious.
EOF
            exit 2
        fi

        # Check 6: Empty catch blocks in JS/TS
        FOUND=$(echo "$CONTENT" | grep -Pn '\}\s*catch\s*\([^)]*\)\s*\{\s*\}' 2>/dev/null | head -3 || true)
        if [ -n "$FOUND" ]; then
            cat >&2 <<EOF
[hook:global] BLOCKED: Empty catch block — errors swallowed silently
Rule: Don't catch errors just to ignore them. Handle, log, or let them propagate.
File: $FILE_PATH

Violations found:
$FOUND
EOF
            exit 2
        fi
        ;;
esac

exit 0
