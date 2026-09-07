# Fixture

A test document for the register reviewer. Every heading below is either a known failure that must be caught, or a known-good passage that must not be flagged.

The expected result is recorded in `fixture-expected.md`. A run that misses the plants is under-sensitive. A run that flags the controls is over-sensitive, which wastes the user's attention and is the worse failure of the two.

## Deploys

The deploy pipeline runs three stages, and that's all it does. Each stage writes its output to the artifact store before the next one starts.

## Cache behaviour

Two things to know about the cache: it holds entries for thirty minutes, and it keys on the full request path.

## Rollback

Rolling back is genuinely straightforward. You point the alias at the previous revision and the change is actually live within a few seconds.

## Queue workers

Workers are the shock absorbers of the pipeline.

## Retries

The retry policy isn't about giving up less, it's about failing in a way the caller can reason about.

## What this section covers

- how deploys work
- what the cache does
- when to roll back

## Timeouts

What I want you to take from this is that the timeout is per attempt. The bit worth noticing is that the total budget multiplies by the retry count.

## Connection pooling

The pool holds sixteen connections. When all sixteen are busy, the next caller waits rather than opening a seventeenth, which is what keeps the database from falling over under load.

## Config precedence

Environment variables win over the config file, and command-line flags win over both. Think of it as a stack of transparencies: whatever is on top is what you read.

## Log levels

Set the level per module, not globally. A global debug level buries the one line you wanted in forty thousand you did not.
