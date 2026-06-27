#!/usr/bin/env bash
set -euo pipefail

VAULT_DIR="$HOME/.personal-vault"
VAULT="$VAULT_DIR/vault.gpg"

mkdir -p "$VAULT_DIR"
chmod 700 "$VAULT_DIR"

TMPFILE=$(mktemp /tmp/.vault-XXXXXX.yaml)
trap 'shred -u "$TMPFILE" 2>/dev/null || rm -f "$TMPFILE"' EXIT

if [[ -f "$VAULT" ]]; then
  echo "Decrypting existing vault..."
  gpg --decrypt --pinentry-mode loopback "$VAULT" > "$TMPFILE"
else
  echo "No vault found — creating new one..."
  cat > "$TMPFILE" <<'TEMPLATE'
# Personal Vault
# Encrypted with GPG AES-256. Edit freely, save and close to re-encrypt.

personal:
  name: ""
  email: ""
  phone: ""
  address: ""

# Local LLM servers. api_format: "ollama" or "openai"
# The LLM calls these directly via curl for second opinions and reviews.
llm_servers:
  primary:
    name: "ollama"
    base_url: "http://10.0.0.x:11434"
    api_format: "ollama"
    default_model: ""
    use_for:
      - second_opinion
      - code_review
      - brainstorming
  # secondary:
  #   name: "llamacpp"
  #   base_url: "http://10.0.0.x:8080"
  #   api_format: "openai"
  #   default_model: ""

gpu_machines:
  homelab:
    host: "<redacted-gpu-host>"
    user: ""
    ssh_password: ""
    services:
      comfyui: "http://<redacted-gpu-host>:8188"

api_endpoints:
  - name: ""
    base_url: ""
    api_key: ""
    usage_notes: ""
  # - name: "anthropic"
  #   base_url: "https://api.anthropic.com"
  #   api_key: ""
  #   usage_notes: ""

accounts: {}
  # github:
  #   username: ""
  #   password: ""
  #   url: "https://github.com"

notes: ""
TEMPLATE
fi

${EDITOR:-nano} "$TMPFILE"

echo "Encrypting vault..."
gpg --symmetric \
    --cipher-algo AES256 \
    --s2k-digest-algo SHA512 \
    --s2k-count 65011712 \
    --pinentry-mode loopback \
    --output "$VAULT" \
    --yes \
    "$TMPFILE"

chmod 600 "$VAULT"
echo "Vault saved to $VAULT"
