---
name: looper
description: Run long AI work as a durable local worker and reviewer loop (Looper). One agent works; an independent second agent reviews checkpoints or answers research, comparison or access requests; they exchange plain files in a task folder, so any session can restart and continue. Use when the user asks to use Looper, wants independent review or a second agent without relaying messages, or asks to continue, review or check a Looper task or a .looper folder.
license: MIT (see LICENSE)
metadata:
  short-description: Durable worker/reviewer handoff through local files
---

# Looper

This skill folder carries a generated copy of Looper (template, prompts, helper, drivers,
contract). `<skill-dir>` below means the folder containing this file; use it as the Looper home.
Do not edit this copy - it is rebuilt from the Looper repository.

Helper, same commands in either edition:
- PowerShell: `& '<skill-dir>/tools/looper.ps1' status '<task-folder>'` (run it in-process)
- sh: `sh '<skill-dir>/tools/looper.sh' status '<task-folder>'`

## Which role are you?

- **Starting work with Looper, or continuing as the worker:** first look for an existing task
  folder (usually `<project>/.looper`) and continue it if present. Otherwise read
  `<skill-dir>/prompts/worker.md` and follow it.
- **Asked to review or answer a Looper task:** read the task's `.looper/CONTEXT.md`, then
  `<skill-dir>/prompts/reviewer.md`.
- **Asked about the state of a Looper task:** run `status` on the folder and summarise `TASK.md`
  and the latest exchange.

Launching or waking the other agent: `<skill-dir>/drivers/README.md`.
The exact rules (also for working with no scripts): `<skill-dir>/docs/contract.md`.
