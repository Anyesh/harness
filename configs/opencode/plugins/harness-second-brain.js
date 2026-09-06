// Mirrors configs/shared/hooks/session-end-ingest.sh for opencode, which has
// no SessionEnd-style shell hook. opencode's plugin API exposes session.idle
// as the closest analog (fires when the agent stops actively working), not a
// true end-of-session event, so ingestion may fire more than once per
// session; that matches second-brain's own idempotent-ingest design.
export const HarnessSecondBrain = async ({ $ }) => {
  const SB_API = process.env.SECOND_BRAIN_API || "http://127.0.0.1:7200"

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return

      let healthy = false
      try {
        const res = await fetch(`${SB_API}/v1/status`, { signal: AbortSignal.timeout(2000) })
        healthy = res.ok
      } catch (err) {
        healthy = false
      }
      if (!healthy) return

      try {
        await $`sb ingest`.nothrow().quiet()
      } catch (err) {
        return
      }
    },
  }
}
