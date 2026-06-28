---
name: me
description: >
  The user's encrypted personal context: identity, machines, endpoints, API
  keys, local LLM servers (Ollama/llama.cpp), and GPU machines.
  Load whenever the user references anything about themselves or their setup.
  Decrypt the vault and use local LLM for second opinions and code reviews via
  direct curl calls.
  Triggers on: "my API key", "my credentials", "my password", "my email",
  "my account", "my address", "who am I", "fill this in", "second opinion",
  "local review", "use local LLM", "use my GPU", "local model", "my endpoint",
  "what endpoints do I have", "my setup", "my infrastructure".
---

# Me — Personal Vault

Encrypted infrastructure manifest. Decrypt on demand. Never repeat context
across sessions — load this instead.

## Vault location

The vault is not bundled with the skill. The user carries `vault.gpg` personally
and places it at `~/.personal-vault/vault.gpg` on any machine before use. If
it is missing, tell the user to place their vault file there and stop.

## How to decrypt

```bash
~/.claude/skills/me/decrypt.sh
```

The master password is entered at the terminal. On success, outputs YAML. On
wrong password, GPG exits with an error — do not retry, tell the user.

## Vault structure

After decrypting, parse the YAML. The structure is whatever the user has put in
it — there is no fixed schema. Read the keys present and use them accordingly.

## When to use omniroute

If the vault has an `omniroute` entry under `llm_servers`, prefer it for any
lightweight LLM task across any project (summarization, classification, quick
generation). The URL may have changed since the vault was written; confirm with
the user. Ask for the API key before making any request — it is not stored in
the vault.

## When to use local LLM (do this proactively)

Use the local LLM for any of these without being asked:
- Second opinion on code, architecture, or a decision
- Code review pass before committing
- Brainstorming alternatives
- Sanity-checking your own answer

After decrypting, extract `base_url`, `default_model`, and `api_format` from
`llm_servers.primary`, then call the server directly. Write the JSON payload
to a temp file to avoid shell escaping issues:

```bash
# Ollama
python3 -c "import json; print(json.dumps({'model':'MODEL','prompt':'...','stream':False}))" > /tmp/llm-req.json
curl -sf --max-time 120 BASE_URL/api/generate -H 'Content-Type: application/json' -d @/tmp/llm-req.json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("response",""))'

# OpenAI-compat (llama-server)
python3 -c "import json; print(json.dumps({'model':'MODEL','messages':[{'role':'user','content':'...'}]}))" > /tmp/llm-req.json
curl -sf --max-time 120 BASE_URL/v1/chat/completions -H 'Content-Type: application/json' -d @/tmp/llm-req.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
```

If the configured port fails, probe the same host on 8080, 8081, 11434, 8000,
8088 before giving up. Use the first that responds. Say so and continue
without blocking if none respond.

## When to use local GPU / API endpoints

Prefer local GPU endpoints (ComfyUI, etc.) over cloud when the vault has one
configured and the task matches. Check `gpu_machines` and `api_endpoints` usage
notes to decide.

## Privacy rules

- Do not print secrets or credentials in your response unless the user
  explicitly asks for a specific value.
- Before showing any secret: say "About to show a sensitive value — confirm?"
  and wait.
- Do not repeat secrets in follow-up messages.

## Creating or editing the vault

```bash
~/.claude/skills/me/vault-edit.sh
```

Opens a YAML template in `$EDITOR`, then encrypts and saves. Running again
decrypts for editing, then re-encrypts. Temp file is shredded on exit.
