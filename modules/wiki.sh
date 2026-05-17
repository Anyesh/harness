#!/usr/bin/env bash

wiki_check() {
  local vault="${WIKI_VAULT:-}"
  if [[ -z "$vault" ]]; then
    if [[ -f "$HOME/.harness.env" ]]; then
      vault=$(grep -E '^WIKI_VAULT=' "$HOME/.harness.env" 2>/dev/null | cut -d= -f2- || true)
    fi
  fi

  if [[ -z "$vault" ]]; then
    log_warn "WIKI_VAULT not set"
    log_info "  Set WIKI_VAULT in ~/.harness.env"
    return 1
  fi

  return 0
}

wiki_install() {
  local vault="${WIKI_VAULT:-}"
  if [[ -z "$vault" ]]; then
    if [[ -f "$HOME/.harness.env" ]]; then
      vault=$(grep -E '^WIKI_VAULT=' "$HOME/.harness.env" 2>/dev/null | cut -d= -f2- || true)
    fi
  fi

  if [[ -z "$vault" ]]; then
    vault="$HOME/Obsidian/SecondBrain"
    log_info "WIKI_VAULT not set, defaulting to $vault"
  fi

  wiki_init_vault "$vault"
  wiki_ensure_env "$vault"

  log_info "wiki hooks (session-start-wiki.sh, session-end-ingest.sh) deployed by claude module"
  log_info "wiki maintenance happens during sessions via /wiki skill (no background export)"
}

wiki_init_vault() {
  local vault="$1"

  if [[ -f "$vault/WIKI_SCHEMA.md" ]]; then
    log_skip "wiki vault" "already initialized at $vault"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would initialize wiki vault at $vault"
    return
  fi

  local today
  today=$(date +%Y-%m-%d)

  mkdir -p "$vault/wiki/projects"
  mkdir -p "$vault/wiki/concepts"
  mkdir -p "$vault/wiki/synthesis"
  mkdir -p "$vault/wiki/sources"
  mkdir -p "$vault/raw/assets"

  cat > "$vault/wiki/index.md" <<INDEXEOF
---
type: index
created: ${today}
updated: ${today}
---

# Wiki Index

Master catalog. The LLM reads this first to find relevant pages.

## Projects

_No projects yet._

## Concepts

_No concepts yet._

## Sources

_No sources yet._

## Syntheses

_No syntheses yet._
INDEXEOF

  cat > "$vault/wiki/log.md" <<LOGEOF
---
type: log
created: ${today}
---

# Activity Log

Append-only. \`grep "^## \[" log.md | tail -5\` for recent entries.
LOGEOF

  cat > "$vault/WIKI_SCHEMA.md" <<SCHEMAEOF
---
vault_name: "wiki"
created: ${today}
version: 2
---

# Wiki Schema

LLM-maintained knowledge wiki (Karpathy pattern). The LLM reads this at the start of every wiki operation. See the /wiki skill (SKILL.md) for full operational instructions.

## Structure

\`\`\`
wiki/
├── projects/<slug>/         # per-project knowledge
│   ├── overview.md
│   ├── devlog.md
│   ├── decisions/
│   ├── plans/
│   ├── spikes/
│   └── concepts/
├── concepts/                # cross-project concepts
├── synthesis/               # cross-project analyses
├── sources/                 # external source summaries
├── index.md                 # master catalog
└── log.md                   # activity timeline
raw/                         # immutable source copies
\`\`\`

## Page Types

- **devlog**: append-only dated entries per project
- **decision**: ADR (Context, Decision, Consequences, Alternatives)
- **plan**: PRD (Goal, Background, Approach, Scope, Open Questions)
- **spike**: exploration (Question, What Was Tried, Findings, Conclusion)
- **concept**: knowledge page (Definition, Explanation, Related, Sources)
- **source**: external source summary (Summary, Key Claims, Entities, Concepts)
- **synthesis**: filed query answers (Question, Answer, Evidence, Sources)

## Quality Rules

- No AI narration, hedging, or attribution to "Claude"
- No session transcripts or play-by-play
- Maximum 2 paragraphs per section unless genuinely needed
- Every claim backed by a source or session context
- Prefer structured lists for facts and tradeoffs
SCHEMAEOF

  log_success "wiki vault initialized at $vault"
}

wiki_ensure_env() {
  local vault="$1"
  local env_file="$HOME/.harness.env"
  local env_example="$REPO_ROOT/.env.example"

  if [[ -f "$env_file" ]] && grep -qE '^WIKI_VAULT=' "$env_file" 2>/dev/null; then
    log_skip "WIKI_VAULT in .harness.env" "already set"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[dry-run] would add WIKI_VAULT=$vault to $env_file"
    return
  fi

  echo "WIKI_VAULT=$vault" >> "$env_file"
  log_success "WIKI_VAULT=$vault added to $env_file"

  if [[ -f "$env_example" ]] && ! grep -qE 'WIKI_VAULT' "$env_example" 2>/dev/null; then
    printf '\n# Path to Obsidian vault for LLM-maintained wiki\n# WIKI_VAULT=~/Obsidian/SecondBrain\n' >> "$env_example"
  fi
}

wiki_test() {
  local tmp_dir
  tmp_dir=$(mktemp -d)

  local orig_home="$HOME"
  local orig_dry="$DRY_RUN"
  local orig_vault="${WIKI_VAULT:-}"

  export HOME="$tmp_dir"
  DRY_RUN=true
  WIKI_VAULT="$tmp_dir/test-vault"
  echo "WIKI_VAULT=$tmp_dir/test-vault" > "$tmp_dir/.harness.env"

  local output
  output=$(wiki_install 2>&1)

  HOME="$orig_home"
  DRY_RUN="$orig_dry"
  WIKI_VAULT="$orig_vault"
  rm -rf "$tmp_dir"

  if ! echo "$output" | grep -q '\[dry-run\]'; then
      log_error "wiki_test: no dry-run output produced"
      return 1
  fi

  return 0
}
