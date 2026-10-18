---
name: standup
description: Example profile-only skill. Draft a three-line standup (yesterday, today, blockers) from the current repo's git log since the last working day. Triggers on: "standup", "write my standup".
---

Read `git log --since` the last working day for the current author, group the commits by topic, and write three short lines: what was done, what is next, and anything blocked. Plain prose, no bullets inside a line.
