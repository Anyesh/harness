// Writes the context size of an opencode crew worker to the usage file
// crew-sweep reads (crew_session_usage in crew-lib.sh). herdr reports no session
// id for opencode, so the file is keyed by the herdr pane instead.
import { mkdir, rename, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

function usageFile(pane) {
  const state = process.env.XDG_STATE_HOME || join(homedir(), ".local", "state")
  return join(state, "harness", "usage", "sessions", `pane-${pane.replace(/[^A-Za-z0-9_-]/g, "_")}.json`)
}

async function writeUsage(file, tokens) {
  const tmp = `${file}.${process.pid}.tmp`
  try {
    await mkdir(join(file, ".."), { recursive: true })
    await writeFile(tmp, JSON.stringify({ profile: "opencode", context_tokens: tokens, context_window: null }))
    await rename(tmp, file)
  } catch (err) {
    console.error(`harness-crew-usage: cannot write ${file}: ${err.message}`)
  }
}

export const HarnessCrewUsage = async ({ client }) => {
  const pane = process.env.HERDR_PANE_ID
  const isRoot = new Map()

  async function rootSession(id) {
    if (!isRoot.has(id)) {
      try {
        const res = await client.session.get({ path: { id } })
        isRoot.set(id, !res?.data?.parentID)
      } catch (err) {
        console.error(`harness-crew-usage: session.get failed: ${err.message}`)
        return false
      }
    }
    return isRoot.get(id)
  }

  return {
    event: async ({ event }) => {
      if (!pane || event.type !== "message.updated") return
      const info = event.properties?.info
      if (info?.role !== "assistant" || !info.time?.completed || !info.sessionID) return
      const t = info.tokens || {}
      const tokens = (t.input || 0) + (t.cache?.read || 0) + (t.cache?.write || 0)
      if (tokens <= 0) return
      if (!(await rootSession(info.sessionID))) return
      await writeUsage(usageFile(pane), tokens)
    },
  }
}
