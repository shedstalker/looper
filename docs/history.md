# History and lessons

Why Looper exists and why it is deliberately simple. Read this when a design choice looks odd;
most of them were paid for by real friction.

## Origin

Looper was extracted from a real, long-running AI development workflow on a private software
project in September 2026. One agent (Claude Code) did the work, a second (Codex)
independently reviewed checkpoints, and at first the project owner carried every message
between them by hand. That project was the proving ground; it does not own Looper, and nothing
specific to it belongs here. Looper was then rebuilt as a standalone project and tested
independently (see `testing.md`).

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

- **The shared TASK file is the durable working memory.** Sessions compacted, restarted and
  were replaced; the work continued because TASK recorded it. -> `TASK.md` is free-form and shared.
- **Agent sessions are disposable.** -> every role can cold-start from `CONTEXT.md`; resuming a
  session is an optimisation, never a requirement.
- **Exact candidate identity matters, but templates must stay light.** Commit + tree was essential
  for source work; mandatory hash fields everywhere were friction. -> only the `Handoff:` line is
  required in an answer (plus `Verdict:` for reviews); the rest is proportionate prose.
- **Filenames and labels are bad filters.** A differently named "final" file fell outside the
  watcher's pattern; later, reviewers had to be told never to filter on words like "final".
  -> one handoff file; due-ness depends on content identity, never on labels.
- **Same-source new evidence still needs review; byte-identical repeats do not.** -> a handoff's
  id is the hash of its bytes.
- **A failed reviewer run must not consume a handoff.** Reviewer runs failed mid-review (lost
  command runner, sandbox errors). -> a handoff is settled only by a published answer naming it;
  a failed attempt publishes nothing, so the work stays due.
- **Detection is not activation.** The first file watcher only logged; the heartbeat did the
  waking. -> drivers both detect and launch; a heartbeat remains an honest option.
- **Heartbeat prompts must be tiny.** A scheduled review prompt grew into a long paragraph of
  task-specific instructions that went stale as the task moved on. -> the wake-up prompt is one
  line; state and instructions live in the task folder.
- **Events are hints; rescans are truth.** File events can duplicate or be missed. -> scan before
  every wait, poll as a fallback.
- **In-memory watcher state is not restart state.** -> watchers keep no state at all.
- **Git/source remains code truth.** -> Looper never records source state of its own.
- **Watchers move attention, never decide.** -> drivers only wait, launch and re-read.
- **Constrain outcome and proof, not reasoning** (research done in the originating project on
  "bounded agency"). -> PLAN = outcome, context, boundaries, proof, escalation; the reviewer
  judges results, not obedience to a method.
- **Stay model-agnostic.** Claude + Codex was the first proven pair, not the architecture.

## Development of this repository

See `testing.md` for the evidence and `decisions.md` for the reasons behind each design choice.
