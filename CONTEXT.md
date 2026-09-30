# CONTEXT - Looper (start here)

You are in **Looper**, a minimal, model-agnostic, local worker/reviewer handoff built from ordinary
files. Read this file first, then only what your task needs.

## What owns truth

- **This repository** (`shedstalker/looper`) is Looper's public release and product repository.
  Looper was developed privately through v0.1.0 (Level 1 Basic) and v0.2.0 (Level 1 Deluxe);
  public distribution begins with **v0.2.1 - Level 1 Deluxe**; the current release is
  **v0.3.1 - Level 1 Deluxe** (v0.3.0's OpenCode route, attachments and fixes, plus fixes from an
  outside review). Nothing beyond Level 1 is
  implemented here. Development and release qualification happen in the maintainers' development
  repository; changes arrive here as reviewed releases (README, "Issues and changes").
- **A task's `.looper/` folder** owns that task's state (it is created from `template/`).

## Route by task

| You want to... | Read |
|---|---|
| Understand Looper quickly | `README.md` |
| **Use** Looper as a worker | `prompts/worker.md` |
| **Use** Looper as a reviewer | the task's `.looper/CONTEXT.md`, then `prompts/reviewer.md` |
| Run an agent (visible/headless/manual, model, effort, sessions, local models) | `drivers/README.md`, then `drivers/<provider>/` |
| Consider another agent CLI (why only three runtimes have drivers) | `drivers/others.md`, `docs/decisions.md` D24 |
| Report a problem or propose a change | `CONTRIBUTING.md` |
| Know the exact rules (due rule, identity, publishing) | `docs/contract.md` |
| Understand why it is this simple | `docs/history.md`, then `docs/decisions.md` |
| Understand the design lineage (ICM, agent as file) and the name | `docs/history.md` |
| See what is proven | `docs/testing.md`, `tests/acceptance.ps1`, `tests/evidence/` |
| See what each version delivered | `CHANGELOG.md` |
| Package it as an Agent Skill | `integrations/skill/README.md` |
| Make another system's agents ask for review | `integrations/host-snippet.md` |

## Layout

```text
template/          task-folder template (copied by `new`, either helper)
prompts/           worker.md, reviewer.md - provider-neutral role rules
tools/             looper.ps1 + looper.sh - the only core code (same behaviour): new | status | publish | wait | clean
drivers/           generic/ (agent-loop.ps1), claude-code/, codex/, opencode/ (the three supported runtimes)
integrations/skill thin Agent Skill source + build script (generated output in dist/, not committed)
examples/          hello-looper - a real completed run
tests/             acceptance.ps1 (no model calls) + evidence/ from live runs
docs/              contract, decisions, history, testing
```

## Rules for changing Looper

Keep Level 1 boring: add nothing unless an acceptance check or real use fails without it.
The core (`template/`, `prompts/`, `tools/`, `docs/contract.md`) never names a provider.
Run `pwsh -File tests/acceptance.ps1` (and `-Helper sh`) before proposing a change, and explain real
design choices in the terms used by `docs/decisions.md`.
