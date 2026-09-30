## Spawn pattern (concrete)

Per round, the parent issues one message containing all reviewer `Agent` calls in
parallel, each with a self-contained prompt (work product + scope block + gate
status + persona brief + response contract). Use `general-purpose` as the subagent
type, or a specialized type where it fits a seat (e.g. `feature-dev:code-reviewer`
for correctness/edge-cases). The parent waits for all reviewers, then synthesizes.
The parent is the worker and the orchestrator; it does not critique, and reviewers
never critique each other.
