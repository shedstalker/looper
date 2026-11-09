# History and lessons

Why Looper exists and why it is deliberately simple. Read this when a design choice looks odd;
most of them were paid for by real friction.

## Origin

Looper was extracted from a real, long-running AI development workflow on a private software
project in September 2026. One agent (Claude Code) did the work, a second (Codex)
independently reviewed checkpoints, and at first the project owner carried every message
between them by hand. That project was the proving ground; it does not own Looper, and nothing
specific to it belongs here. Looper was then rebuilt as a standalone project and tested
independently (see [testing](testing.md)).

The workflow evolved in three steps:

1. **Commit-named files.** A folder outside Git held one handoff file and one review file per
   commit. Two small PowerShell watchers (file events plus 5-second rescans, temp-then-rename
   publication, two identical reads before trusting a file) spotted new files, and a scheduled
   five-minute "heartbeat" task actually woke the reviewer. Overnight, the pair iterated
   REPAIR -> fix -> PASS without the human.
2. **Fixed names and hashes.** Fixed files (`TASK.md`, `HANDOFF.md`, `REVIEW.md`) replaced the
   commit-named ones. Reviews recorded the SHA-256 of the handoff they reviewed, so "is this
   handoff settled?" became a pure function of the files. `TASK.md` grew to several hundred lines
   and became the pair's genuinely useful shared memory across many sessions.
3. **A reusable package.** The pattern was written down as a specification and templates, and
   built as this repository: **Level 1 Basic (v0.1.0)**, the minimal protocol, and then **Level 1
   Deluxe (v0.2.0)**, the same protocol hardened by repeated real use and dogfooding (developed
   as the "L1.1" pass; some evidence still uses that working name).

## Lineage

```text
ICM            an interpretable information environment
  -> agent as file   durable agent state kept in that environment
  -> Looper          independent models working through that durable state
```

- **Interpretable Context Methodology (ICM).** Looper was influenced by ICM, associated with Jake
  Van Clief and David McDermott. The idea Looper borrows is that the information environment can
  be deliberately structured so a capable agent orients itself from it: the filesystem is part of
  the interface presented to the intelligence, not merely storage. Looper's `CONTEXT.md` router
  and its small, named files are that idea applied to one bounded handoff. Looper does not claim
  to have invented ICM, filesystem-based context or Markdown state.
- **Agent as file.** Model session = disposable working context; files = durable, interpretable
  agent state. Looper does not transfer hidden context windows or provider-specific reasoning
  between models; it externalises only what must survive (the plan, the working memory, the
  current request and answer, the history). Any capable session or compatible model can pick the
  work up from there, which is why the same task folder works across Claude, Codex, OpenCode or a
  local model.

## The name

The work naturally forms a loop: the worker packages bounded work and evidence into a HANDOFF, an
independent agent deals with it and leaves a REVIEW or result, and the worker continues or
repairs - loop closed. It is also a light nod to the film *Looper*, where a job turns up for an
independent operator to deal with and the loop eventually gets closed. (For a while it was
jokingly "Bruce", after Bruce Willis; "Looper" won because the software meaning stands on its own.)

## Lessons carried into Looper

The formal decisions are in [decisions](decisions.md); these are the failures behind them:

- Sessions compacted, restarted or disappeared; a shared TASK file kept the work moving.
  Files hold durable state, and sessions can always cold-start from CONTEXT.
- Commit + tree identified source precisely, but mandatory hash fields everywhere added friction.
  Answers need only handoff identity, with a verdict for reviews (D2-D3).
- A differently named "final" file escaped a watcher's pattern. Fixed filenames and content
  identity replaced labels; new evidence still gets review even when source is unchanged.
- Lost runners and sandbox errors killed reviewers mid-attempt. Only a published answer settles
  work; failed attempts leave it due (D1). In-memory watcher state never owns restart state.
- The first watcher detected files but did not wake an agent; the heartbeat supplied activation.
  Drivers now detect and launch, while events remain hints and rescans remain truth.
- Long scheduled prompts went stale. A wake-up names only the role and task folder; procedure
  and current state stay in files.
- Source control owns source truth; watchers move attention and never judge work or grant authority.
- "Bounded agency" research in the originating project led to PLAN's outcome, context, boundaries,
  proof and escalation: constrain results and evidence, not the agent's reasoning method.
- Claude + Codex was the first tested pair, not an architectural dependency.

## Development of this repository

See `testing.md` for the evidence and `decisions.md` for the reasons behind each design choice.
