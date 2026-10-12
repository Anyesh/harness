// opencode counterpart of post-compact-context.sh. opencode has no hook that
// injects context after compaction, but experimental.session.compacting adds
// text to the compaction prompt itself, so the summary carries the scope
// forward. The note comes from the same compact-note.sh the shell hooks use,
// which modules/opencode.sh deploys next to this plugins directory.
import { execFileSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const NOTE_SCRIPT = fileURLToPath(new URL("../hooks/compact-note.sh", import.meta.url))

export const HarnessCompactScope = async ({ directory, worktree }) => {
  return {
    "experimental.session.compacting": async (_input, output) => {
      let note = ""
      try {
        note = execFileSync("bash", [NOTE_SCRIPT, worktree || directory], {
          encoding: "utf8",
          timeout: 5000,
        }).trim()
      } catch (err) {
        console.error(`harness-compact-scope: compact-note.sh failed: ${err.message}`)
        return
      }
      if (!note) return
      output.context.push(
        `${note}\n\nKeep this scope's definition of done and feedback loop in the summary; it is the task the session is working toward.`,
      )
    },
  }
}
