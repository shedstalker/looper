# OpenCode driver

OpenCode is the route for models that Claude Code and Codex do not run: Grok, local models through
Ollama, and the other providers OpenCode supports. Looper does not choose or route models. You
pick one with `-Model provider/model`, OpenCode runs it, and the task folder stays the same.

Checked with OpenCode 1.18.32 (September 2026), native on Windows and in a Linux container.
Flags change; check the current OpenCode docs.

## Which models have actually passed a Looper handoff

| Model through OpenCode | Status | Sign-in and cost |
|---|---|---|
| Grok (`xai/grok-4.7` requested; OpenCode does not report the model that answered) | **Passed** as reviewer and as worker, including repair rounds, resumed and fresh sessions, native Windows, task folder inside or outside the project (E14-E17) | SuperGrok (or another Grok plan with API access) via `opencode providers login --provider xai --method "SuperGrok Subscription"`: a device code you approve in a browser; no API key |
| Qwen via Ollama | **Passed** one review (E10), in a container | Local and free; needs Ollama, a 64k-context variant and capable hardware |
| Anything else in `opencode models` (Gemini, ...) | **Offered by OpenCode, not tested with Looper** | Each provider has its own sign-in or key, and possibly its own charges |

Listed in `opencode models` only means OpenCode can call it. It does not mean the model can drive
OpenCode's tools well enough to read a task folder and publish through the helper. Try one review
round before relying on a new model. OpenCode's JSON shows a `cost` figure; that is OpenCode's own
price-list estimate, not what your plan charges. Whatever the agent reads is sent to that model's
provider; only a local model keeps it on your machine.

## Reviewer and worker

```powershell
opencode providers login --provider xai --method "SuperGrok Subscription"          # once
pwsh -File drivers/opencode/run.ps1 -Loop <folder> -Model xai/grok-4.7              # reviewer
pwsh -File drivers/opencode/run.ps1 -Loop <folder> -Model xai/grok-4.7 -Role worker
pwsh -File drivers/opencode/run.ps1 -Loop <folder> -Model ollama/qwen36-64k -Show    # local
```

```text
first run:  opencode run --dir <task folder | project> --format json [-m M] [--variant V]    (prompt on stdin)
later runs: the same with -s <session id>
```

- The reviewer runs in the task folder and reads the project; the worker runs in the project.
  The task folder can live anywhere: `<project>/.looper` (the default) or a separate tasks
  directory. Both layouts were tested end to end with Grok in both roles (E17).
- `-Session resume` (default) continues the role's OpenCode session. If OpenCode says
  `Session not found`, the driver cold-starts in the same attempt. `-Session fresh` for a new
  session every time.
- `-Variant` passes OpenCode's reasoning variant, where the model has one.
- The log records the model as **requested**. OpenCode's output does not say which model answered.
- `-Show` streams the run; `opencode --session <id>` opens the session afterwards.
- The CLI is found on `PATH`; otherwise `-OpenCode <path>`.

## Permissions: guardrails, not a sandbox

OpenCode has no operating-system sandbox. Its defaults allow most actions. In `opencode run`
anything that would ask is refused, since nobody is there to answer. The driver passes these
rules through `OPENCODE_PERMISSION`, which OpenCode merges over your own config:

- **Reviewer:** may edit only `EXCHANGE/REVIEW.next.md`, `TASK.md` and `WATCHERS/scratch/`.
- **Worker:** may edit anything except the reviewer's `REVIEW` files.
- **Both:**
  - may read, search and run commands, including tests and the helper;
  - paths outside the project are refused, except the task folder and the Looper home;
  - web fetch, web search and subagents are refused.

In testing, a refused edit stayed refused. But a role that can run commands can do anything your
account can. Once, when a misconfigured rule blocked its answer file, Grok wrote the file through
a shell command instead. Treat these rules as protection against accidents, not containment. For
a hard boundary, run OpenCode in a container or VM with only the project mounted; the test setup
is in `docs/testing.md` (E14).

`-Permission own` skips these rules and uses your OpenCode config unchanged. Never use `--auto`
(it approves everything not explicitly denied).
