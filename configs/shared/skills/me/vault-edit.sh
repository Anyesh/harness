#!/usr/bin/env bash
set -euo pipefail

VAULT_DIR="$HOME/.personal-vault"
VAULT="$VAULT_DIR/vault.gpg"
INIT_FILE="/tmp/.vault-init.yaml"

mkdir -p "$VAULT_DIR"
chmod 700 "$VAULT_DIR"

TMPFILE=$(mktemp /tmp/.vault-XXXXXX.yaml)
trap 'shred -u "$TMPFILE" 2>/dev/null || rm -f "$TMPFILE"' EXIT

if [[ -f "$VAULT" ]]; then
  echo "Decrypting existing vault..."
  gpg --decrypt --pinentry-mode loopback "$VAULT" > "$TMPFILE"
elif [[ -f "$INIT_FILE" ]]; then
  echo "Using pre-written init file..."
  cp "$INIT_FILE" "$TMPFILE"
  shred -u "$INIT_FILE" 2>/dev/null || rm -f "$INIT_FILE"
else
  echo "No vault found — creating new one..."
fi

${EDITOR:-nano} "$TMPFILE"

echo "Encrypting vault..."
gpg --symmetric \
    --cipher-algo AES256 \
    --pinentry-mode loopback \
    --output "$VAULT" \
    --yes \
    "$TMPFILE"

chmod 600 "$VAULT"
echo "Vault saved to $VAULT"
