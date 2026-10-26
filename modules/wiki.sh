#!/usr/bin/env bash

# Env file only: settings env would carry a profile's vault into a main install.
wiki_check() {
  if [[ -z "$(profile_wiki_vault)" ]]; then
    log_warn "WIKI_VAULT not set"
    log_info "  Set WIKI_VAULT in ~/.harness.env"
    return 1
  fi

  return 0
}

wiki_install() {
  local base vault
  base=$(harness_env_file_value WIKI_VAULT)

  if [[ -z "$base" ]]; then
    base="$HOME/Obsidian/SecondBrain"
    log_info "WIKI_VAULT not set, defaulting to $base"
    wiki_ensure_env "$base"
  fi

  vault=$(profile_wiki_vault)
  # The work vault arrives through sync; a local skeleton would conflict with it.
  if profile_work && [[ ! -f "$vault/WIKI_SCHEMA.md" ]]; then
    log_warn "work wiki vault not synced yet at $vault; wiki hooks stay quiet until it is"
  else
    wiki_init_vault "${vault:-$base}"
  fi

  log_info "wiki hooks (session-start-wiki.sh, stop-wiki-enforce.sh, wiki-index-build.sh) deployed by the agent modules"
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

LLM-maintained knowledge wiki (Karpathy pattern). The LLM reads this at the start of every wiki operation. See the /wiki skill (SKILL.md and its references/ files) for full operational instructions.

## Structure

\`\`\`
wiki/
├── projects/<slug>/         # per-project knowledge
│   ├── index.md             # lists every page in this folder
│   ├── overview.md
│   ├── devlog.md
│   ├── decisions/
│   ├── plans/
│   ├── spikes/
│   └── concepts/
├── concepts/                # cross-project concepts
├── synthesis/               # cross-project analyses
├── sources/                 # external source summaries
├── index.md                 # generated from each folder's index.md; never edit
└── log.md                   # activity timeline
raw/                         # immutable source copies
\`\`\`

Each folder (\`projects/<slug>/\`, \`concepts/\`, \`sources/\`, \`synthesis/\`) keeps its own \`index.md\`, one line per page. Agents edit those; the harness rebuilds \`wiki/index.md\` from them. The project slug is the basename of the main checkout, never a worktree.

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
  local orig_env="$HARNESS_ENV"
  local orig_work="$WORK"

  export HOME="$tmp_dir"
  DRY_RUN=true
  WORK=""
  HARNESS_ENV="$tmp_dir/.harness.env"
  echo "WIKI_VAULT=$tmp_dir/test-vault" > "$HARNESS_ENV"

  local output
  output=$(wiki_install 2>&1)

  HOME="$orig_home"
  DRY_RUN="$orig_dry"
  HARNESS_ENV="$orig_env"
  WORK="$orig_work"
  rm -rf "$tmp_dir"

  if ! echo "$output" | grep -q '\[dry-run\]'; then
      log_error "wiki_test: no dry-run output produced"
      return 1
  fi

  return 0
}
