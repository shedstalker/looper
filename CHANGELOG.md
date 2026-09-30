# Changelog

Looper follows semantic versioning within **Level 1**: one worker, one independent second agent,
durable state in ordinary files. Nothing beyond Level 1 is part of these releases.

Looper was developed privately through v0.1.0 and v0.2.0. **Public distribution begins with
v0.2.1**; the entries below v0.2.1 describe that development lineage, not earlier releases of the
public repository.

## v0.3.0 - Level 1 Deluxe

Same Level 1 protocol and task folder. Adds a third runtime route and optional attachments for
files outside Git, plus helper and driver fixes found in real use:
- `drivers/opencode/`: OpenCode driver (`-Model provider/model`), the route for Grok (tested with
  a SuperGrok subscription), local models through Ollama and other providers. Per-role permission
  guardrails; its README says plainly that they are rules, not a sandbox.
- `drivers/README.md`: "Pick a runtime" - Claude Code, Codex, OpenCode or any agent by hand. For
  each: which models have actually passed a Looper handoff, and the access boundary. Also how to
  get a second opinion on the same checkpoint with a separate task folder (no protocol change).
- Helper: after publishing a review, `publish` prints the recomputed next move (`done` after a
  final PASS) instead of always `worker`. Both editions; covered by the acceptance suite.
- Helper `wait` (PowerShell): a publish that landed while the waiter was re-reading the files
  could go unnoticed until the next poll (up to 30 s by default). Events are now queued for the
  whole wait. This was the suite's long-standing intermittent failure.
- Drivers: Codex `-Extra` now works on resumed sessions (use `-c` settings; `codex exec resume`
  rejects `--add-dir`), and `-Local` always starts fresh. Claude Code `-Local` and the OpenCode
  driver restore the caller's environment variables when they finish.
- Helper: the done rule compares each file's write time as read together with its content. A
  status run during a publish could pair an old PASS with the new handoff's time and report
  `done` early (a reviewer driver then exited). Both editions.
- OpenCode driver: the reviewer runs in the task folder, so task folders outside the project work
  (a separate tasks directory, as used in real projects).
- Helper: `publish ... handoff -Attach <file>,...` for files outside Git. It snapshots them into
  `HISTORY/<number>_attachments/` and lists each one's size and SHA-256 in the handoff, so the
  reviewer reads an immutable local copy (from real use: a Drive document the reviewer's sandbox
  could not reach, and hashes written by hand). Both editions.
- From the same real use, in the docs:
  - `wait -For worker` is the way to learn the verdict (no log parsing);
  - the final report's status is the worker's claim;
  - resume while rounds build on each other, and use a fresh session for the final review;
  - how an agent starts a watchable driver without stale windows;
  - `integrations/host-snippet.md`, a paragraph other systems can paste into their prompts.
- Drivers: `-Effort` is passed through for the runtime to validate (Codex now offers `max` and
  `ultra`, which the old fixed list rejected). The model examples and guidance are current as of
  late September 2026: `gpt-6.1-sol` (`high` for checkpoints, `xhigh` for gates and final reviews,
  `gpt-6-astra` only as an optional final second opinion) and Claude Opus 5.5. Defaults belong in
  each runtime's own config.
- Helper `looper.sh`: `clean` under Git Bash (no `flock`) now checks a driver's lock instead of
  deleting runtime files while the driver runs; elsewhere without `flock` it refuses. An absolute
  Windows `-Draft` path (`C:\...`, `C:/...`) is no longer treated as relative.
- Acceptance suite: 48 checks (was 39 at v0.2.x).
- Evidence: E14-E19 in `docs/testing.md`.

## v0.2.1 - Level 1 Deluxe (first public release; documentation)

No behaviour changes. Clearer positioning (Level 1 Basic / Level 1 Deluxe), design lineage
(agent as file, ICM inspiration) and the name in `docs/history.md`; the acceptance suite's privacy
check now looks for real user-profile paths. First release prepared for public distribution.

## v0.2.0 - Level 1 Deluxe (private development release)

The same Level 1 protocol made comfortable for repeated real use:
- session resume by default, with a cold start only when the runtime says the session is gone;
  `-Session fresh` for maximum independence;
- model and reasoning-effort selection, logged as requested vs. what the runtime reported;
- watchable headless runs (`-Show`) with printed resume commands; interactive and manual modes;
- local models through existing runtimes (Claude Code or OpenCode with Ollama);
- lifecycle hygiene: `clean`, `WATCHERS/scratch/`, one task folder per task;
- an Agent Skill package for Claude Code and Codex (tested) and ChatGPT surfaces that support skill
  installation (validated package; not yet exercised there);
- hardening found by real use: a failed replace publishes nothing, re-published handoff text is
  refused, Codex Windows sandbox file ownership is handled;
- MIT licence.

## v0.1.0 - Level 1 Basic (private development release)

The original, deliberately minimal protocol: CONTEXT, PLAN, TASK, HANDOFF, REVIEW, HISTORY,
WATCHERS and FINAL_REPORT in a task folder; whose move it is is recomputed from the files; stale
answers cannot settle new work; interrupted reviews leave work due; works with no scripts at all.
