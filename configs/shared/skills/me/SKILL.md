---
name: me
description: >
  Plain reference facts about the user's setup: what kinds of machines and
  self-hosted services are available, and which to prefer for a given task.
  No secrets, no hostnames, no IPs live here — load this for context, then
  ask the user directly for any current endpoint or credential.
  Triggers on: "my setup", "my infrastructure", "my machines", "who am I",
  "second opinion", "local review", "use local LLM", "use my GPU",
  "local model", "my endpoint", "what endpoints do I have", "deploy this",
  "where should I deploy", "self-host", "homelab", "my server", "my Pi",
  "Raspberry Pi", "NAS", "auth server", "notification", "mail server",
  "SMTP", "uptime", "status page", "what services do I have", "my stack",
  "what do I run", "available services".
---

# Me — Personal Context

Facts only, no secrets, no hostnames, no IPs, no file paths. When a task
needs an actual endpoint, API key, password, or token, ask the user directly
in the moment — never store or guess one here.

## Identity

- Anish Shrestha, GitHub `anyesh`

## Machines

- A GPU workstation is available for heavier local inference. Ask the user
  for the current host and port before using it.
- A homelab server runs several self-hosted apps (file sync, budgeting,
  order management) with scheduled backups.
- Networked storage is available for shared files. Some encrypted folders
  need a manual remount after a reboot — ask the user if something looks
  unmounted.

## Self-hosted services

- A local LLM endpoint is available for lightweight tasks (summarization,
  classification, quick generation). Ask the user for the current URL and
  key.
- A PII/privacy filtering service is available.
- Self-hosted notification, email, auth, and uptime-monitoring services are
  running. Ask the user for current details before relying on any of them.

When a task needs deployment, auth, notifications, email, or monitoring,
check with the user whether a self-hosted option should be preferred over
external SaaS — do not assume specifics.

## LLM endpoint preference

- **Lightweight tasks** (summarization, classification, quick generation):
  prefer the user's self-hosted endpoint first. Ask for the current URL and
  API key before making a request — never assume either is unchanged.
- **Heavier local inference**: use the GPU workstation. Ask the user for the
  current host and port, then call the OpenAI-compatible endpoint directly.

Use the local LLM proactively for: a second opinion on code or a decision, a
review pass before committing, brainstorming alternatives, or sanity-checking
your own answer.

## Updating this file

This is a plain file, not a vault — edit it directly with the Edit tool when
the user shares a new fact. Never add an API key, password, token, IP
address, hostname, domain name, or file path to it — describe capabilities
generically and ask the user for specifics at use time.
