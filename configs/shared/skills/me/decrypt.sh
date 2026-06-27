#!/usr/bin/env bash
set -euo pipefail

VAULT="$HOME/.personal-vault/vault.gpg"

if [[ ! -f "$VAULT" ]]; then
  echo "ERROR: vault not found at $VAULT" >&2
  echo "Create it first: ~/.claude/skills/personal/vault-edit.sh" >&2
  exit 1
fi

gpg --decrypt --pinentry-mode loopback "$VAULT"
