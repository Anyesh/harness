---
name: me
description: >
  Plain reference facts about the user's setup: machines, self-hosted
  services, and which LLM endpoint to prefer for a given task. No secrets
  live here — load this for context, then ask the user directly for any
  actual credential.
  Triggers on: "my setup", "my infrastructure", "my machines", "who am I",
  "second opinion", "local review", "use local LLM", "use my GPU",
  "local model", "my endpoint", "what endpoints do I have", "deploy this",
  "where should I deploy", "self-host", "homelab", "my server", "my Pi",
  "Raspberry Pi", "NAS", "Terramaster", "auth server", "Pocket ID",
  "notification", "ntfy", "mail server", "SMTP", "uptime", "status page",
  "what services do I have", "my stack", "what do I run", "available services".
---

# Me — Personal Context

Facts only, no secrets. When a task needs an actual API key, password, or
token, ask the user directly in the moment — never store or guess one here.

## Identity

- Anish Shrestha, GitHub `anyesh`

## Machines

- **chihiro** — Windows GPU box, RTX 4070 Ti Super (16GB VRAM). llama.cpp at
  `<redacted-path>`, SSH as `<redacted-gpu-host>`. ComfyUI on `:8188`,
  llama-server on `:8080` by default.
- **Homelab Pi** — runs Seafile + Seadoc (file sync), Actual Budget (finance
  tracker), Pawpfect order management (Postgres + file uploads, Docker).
  Daily 2 AM cron backs up Docker volumes and directories to the NAS.
- **TerraMaster NAS (TOS)** — <redacted-nas-host>, shared at
  <redacted-nas-share>, mounted on the Pi at `/mnt/nas`. TOS does not
  auto-mount eCryptfs-encrypted folders after reboot — they need a manual
  mount via the TOS UI or CLI each time the NAS reboots.

## Self-hosted services

- <redacted-llm-endpoint> — llama.cpp, Qwen2.5-0.5B Q4_K_M, OpenAI-compatible
  `/v1/chat/completions`.
- <redacted-privacy-filter-endpoint> — ONNX privacy filter, PII redaction via `POST /redact`.
- <redacted-email-endpoint> — Listmonk, transactional email.
- ntfy — self-hosted on the Miko VPS, used for notifications.
- Pocket ID, self-hosted mail, Uptime Kuma — running, host details not yet
  recorded here. Ask the user for the current host before relying on one.

When a task needs deployment, auth, notifications, email, monitoring, or
photo storage, check this list before reaching for an external SaaS.

## LLM endpoint preference

- **Lightweight tasks** (summarization, classification, quick generation):
  prefer <redacted-llm-endpoint> first. Confirm the URL is still current and ask the
  user for the API key — it is not stored here.
- **Heavier local inference**: use `chihiro`. Call the llama-server
  OpenAI-compatible endpoint directly:

```bash
python3 -c "import json; print(json.dumps({'model':'MODEL','messages':[{'role':'user','content':'...'}]}))" > /tmp/llm-req.json
curl -sf --max-time 120 http://<redacted-gpu-host>:8080/v1/chat/completions -H 'Content-Type: application/json' -d @/tmp/llm-req.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
```

  If `:8080` doesn't respond, probe `:8081`, `:11434`, `:8000`, `:8088` on the
  same host before giving up. Say so and continue without blocking if none
  respond.

Use the local LLM proactively for: a second opinion on code or a decision, a
review pass before committing, brainstorming alternatives, or sanity-checking
your own answer.

## Updating this file

This is a plain file, not a vault — edit it directly with the Edit tool when
the user shares a new fact. Never add an API key, password, or token to it.
