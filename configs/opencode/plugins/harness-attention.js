// opencode adapter for the attention push (attention-notify.sh covers the
// shell-hook harnesses). opencode has no shell hooks, so this maps bus events
// to arm/cancel calls on attention-core.sh, which modules/opencode.sh deploys
// next to this plugins directory. question.* events appear in opencode issues
// but not its docs, so their payload is read defensively.
import { spawn } from "node:child_process"
import { basename } from "node:path"
import { fileURLToPath } from "node:url"

const CORE = fileURLToPath(new URL("../hooks/attention-core.sh", import.meta.url))

function core(action, payload) {
  return new Promise((resolve) => {
    const child = spawn("bash", [CORE, action], { stdio: ["pipe", "ignore", "pipe"], timeout: 5000 })
    let stderr = ""
    child.stderr.on("data", (chunk) => (stderr += chunk))
    child.on("error", (err) => {
      console.error(`harness-attention: ${action} failed: ${err.message}`)
      resolve()
    })
    child.on("close", (code) => {
      if (code !== 0) console.error(`harness-attention: ${action} exited ${code}: ${stderr.trim()}`)
      resolve()
    })
    child.stdin.end(JSON.stringify(payload))
  })
}

function slug(dir) {
  return basename(dir || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
}

function permissionDetail(p) {
  if (p.title) return p.title
  const patterns = Array.isArray(p.patterns) ? p.patterns.join(" ") : ""
  return [p.permission, patterns].filter(Boolean).join(" ") || "Permission requested"
}

function questionDetail(p) {
  return p.questions?.[0]?.question || p.question || "A question is waiting"
}

export const HarnessAttention = async ({ client, directory, worktree }) => {
  // A non-git project reports its worktree as "/", which says nothing.
  const project = slug(worktree && worktree !== "/" ? worktree : directory)

  const arm = (session, kind, detail) =>
    core("arm", { session, kind, harness: "opencode", project, detail, agent_pid: process.pid })

  async function isChild(id) {
    try {
      const res = await client.session.get({ path: { id } })
      return Boolean(res?.data?.parentID)
    } catch (err) {
      console.error(`harness-attention: session.get failed: ${err.message}`)
      return false
    }
  }

  async function lastAssistantText(id) {
    try {
      const res = await client.session.messages({ path: { id } })
      const messages = (res?.data || []).filter((m) => m.info?.role === "assistant")
      const last = messages[messages.length - 1]
      return (last?.parts || [])
        .filter((part) => part.type === "text" && part.text)
        .map((part) => part.text)
        .join(" ")
    } catch (err) {
      console.error(`harness-attention: session.messages failed: ${err.message}`)
      return ""
    }
  }

  return {
    event: async ({ event }) => {
      const p = event.properties || {}
      const session = p.sessionID
      if (!session) return
      switch (event.type) {
        case "permission.asked":
          return arm(session, "block", permissionDetail(p))
        case "question.asked":
          return arm(session, "block", questionDetail(p))
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          return core("cancel", { session })
        case "session.status":
          // Only clears a finished-turn push: nothing documents whether busy
          // is re-sent while a question or permission waits, and it must not
          // cancel those.
          if (p.status?.type === "busy") return core("cancel", { session, kind: "done" })
          return
        case "session.idle":
          if (await isChild(session)) return
          return arm(session, "done", await lastAssistantText(session))
      }
    },
  }
}
