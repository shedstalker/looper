# Changelog

Looper follows semantic versioning within **Level 1**: one worker, one independent second agent,
durable state in ordinary files. Nothing beyond Level 1 is part of these releases.

Looper was developed privately through v0.1.0 and v0.2.0. **Public distribution begins with
v0.2.1**; the entries below v0.2.1 describe that development lineage, not earlier releases of the
public repository.

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
