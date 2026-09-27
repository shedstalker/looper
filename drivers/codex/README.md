# Codex driver

Checked with codex-cli 0.158 (September 2026). Flags change; check the current Codex CLI docs.

## Reviewer - headless (recommended)

```powershell
pwsh -File drivers/codex/run.ps1 -Loop <folder>          # -Role reviewer is the default
pwsh -File drivers/codex/run.ps1 -Loop <folder> -Model gpt-6-sol -Effort high -Show
```

```text
first run:  codex exec --sandbox workspace-write --skip-git-repo-check [--model M] [-c model_reasoning_effort=E] --cd <task folder> -
later runs: codex exec resume --skip-git-repo-check [...] -c sandbox_mode=workspace-write <session id> -
```

- `-Session resume` (default) continues the reviewer's Codex session across handoffs. Resumed
  Codex sessions do **not** keep their sandbox or working directory (tested), so the driver passes
  both again. If Codex reports the session is gone (`no rollout found`), the driver cold-starts a
  fresh session in the same attempt. `-Session fresh` gives every handoff a new session.
- `-Model` / `-Effort` are honoured per run; Codex prints the model, effort, sandbox and session
  it actually used, and the driver logs that next to what was requested.
- `-Show` streams Codex's progress live and prints `codex resume <id>` to open the session.
- `-Local <ollama-model>` runs the same agent on a local model (`--oss`). Wired and failing
  safely, but the Qwen models tested could not use Codex's tools - see `drivers/README.md`.

The sandbox makes the task folder the only writable place; the reviewer can read the project
and run read-only checks. If it must build or test in a writable place, give it one:
`-Extra:"--add-dir C:\scratch"`. The CLI is found on `PATH`, or on Windows in the Codex app's
folder (`%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`); override with `-Codex <path>`.

`codex review --commit <sha>` is a useful check a reviewer may run itself, but the Looper
reviewer is `codex exec` because it must also read PLAN/TASK and publish REVIEW.md.

## Worker - headless

```powershell
pwsh -File drivers/codex/run.ps1 -Loop <folder> -Role worker
```

`codex exec --sandbox workspace-write --cd <project> --add-dir <task folder> -`, resumed on later
wakes (with the task folder passed again as a writable root); TASK.md carries the work either way.

**Commits:** `workspace-write` keeps `.git` read-only, so a sandboxed Codex worker can edit but
not commit (on Windows, `--add-dir <repo>/.git` is refused too; tested 2026-09-27). Choose one:
let the human commit when the worker asks (it will send an access request / park the item),
or run the worker with `-Sandbox danger-full-access` - an explicit security decision for you,
best kept to disposable or well-backed-up checkouts. For an interactive Codex worker, have it run
`looper.ps1 wait <folder> -For worker` as a blocking command between checkpoints, or start a
new session with `Continue the Looper task at <folder> as the WORKER - read its CONTEXT.md.`

## Reviewer - Codex app scheduled task (heartbeat)

The Codex/ChatGPT desktop app can run a prompt on a schedule, even inside an existing chat.
Use only the one-line prompt:

```text
You are the REVIEWER for the Looper task at <folder>. Read <folder>/CONTEXT.md and follow the reviewer route.
```

Each tick costs one small model call even when nothing is due; the reviewer runs `status` and
stops. Never put task details, candidate hashes or procedure into the scheduled prompt: they
go stale, and the task folder already holds them.
