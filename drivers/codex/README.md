# Codex driver

Checked with codex-cli 0.158 and 0.159 (September 2026). Flags and models change; check the
current Codex CLI docs. `gpt-6.1-sol` needed 0.159: 0.158 rejected it.

## Reviewer - headless (recommended)

```powershell
pwsh -File drivers/codex/run.ps1 -Loop <folder>          # -Role reviewer is the default
pwsh -File drivers/codex/run.ps1 -Loop <folder> -Model gpt-6.1-sol -Effort high -Show
pwsh -File drivers/codex/run.ps1 -Loop <folder> -Session fresh -Effort xhigh      # a gate or the final review
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
- `-Local <ollama-model>` runs the same agent on a local model (`--oss`), always with a fresh
  session (`codex exec resume` cannot select the local provider). Wired and failing safely,
  but the Qwen models tested could not use Codex's tools - see `drivers/README.md`.

The sandbox makes the task folder the only writable place; the reviewer can read the project
and run read-only checks. Not everything is readable, though: in real use on Windows the sandbox
could not read a synced Google Drive for desktop folder. For files like that,
the worker attaches them (`publish ... handoff -Attach <file>`), so the reviewer reads the
snapshot inside the task folder. If it must build or test in a writable place, give it one:
`-Extra:"-c sandbox_workspace_write.writable_roots=['C:\scratch']"`. `-Extra` reaches fresh and
resumed runs alike, and `codex exec resume` accepts only some options (`-c`, `-m`, ...; not
`--add-dir` or `--oss`), so pass settings as `-c` config (the `writable_roots` form was tested
on both). The CLI is found on `PATH`, or on Windows in the Codex app's
folder (`%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`); override with `-Codex <path>`.

`codex review --commit <sha>` is a useful check a reviewer may run itself, but the Looper
reviewer is `codex exec` because it must also read PLAN/TASK and publish REVIEW.md.

## Worker - headless

```powershell
pwsh -File drivers/codex/run.ps1 -Loop <folder> -Role worker
```

`codex exec --sandbox workspace-write --cd <project> --add-dir <task folder> -`, resumed on later
wakes (with the task folder passed again as a writable root); TASK.md carries the work either way.

**What a sandboxed Codex builder can do on Windows** (codex-cli 0.159, tested 2026-09-30 with
`codex sandbox -- <command>`, which runs one command in the same sandbox without a model; use it
to check a tool before a run):

| Action | In `workspace-write` |
|---|---|
| Edit files in the project; run Windows PowerShell 5.1 | works |
| PowerShell 7 from the official zip, unpacked to a folder the sandbox accounts can read | works: from a scratch folder Codex had granted, Looper's suite passed 50/50 inside the sandbox; the same zip in `C:\Tools\PowerShell\7` started there |
| PowerShell 7 from the Microsoft Store (`...\WindowsApps\pwsh.exe`) | cannot start ("Access is denied") |
| Tested tools by full path: `git` (read), Git Bash `C:\Program Files\Git\bin\sh.exe`, `gh --version` (with a warning that it cannot read its config) | start |
| Tested executables under `%LOCALAPPDATA%\Programs` (PowerShell 7, OpenCode, Ollama, Docker Desktop's `docker.exe`) | cannot start: the sandbox runs as separate Windows accounts (`CodexSandboxUsers`), and on the tested machine they had no read access there |
| Network | off by default. With `-c sandbox_workspace_write.network_access=true`, Ollama's API on `localhost` answered, but one HTTPS request to github.com failed (`SEC_E_NO_CREDENTIALS`) |
| `wsl -l -q` | refused. A Docker daemon connection was not tested |
| `git commit` in the project's existing repository | refused: its `.git` stays read-only, also when listed in `writable_roots` (and `--add-dir <repo>/.git` was refused on 2026-09-27 with 0.158). A new repository the sandbox creates in a writable folder can commit, but that is not the project |
| `taskkill.exe` | refused, even for its own child processes; `Stop-Process` works on those |

Check any other tool before relying on it: `codex sandbox -- <full path to the program> --version`.

So, for a Codex builder that proves its work on both PowerShell editions: download the official
`PowerShell-<version>-win-x64.zip` from github.com/PowerShell/PowerShell/releases, check its
SHA-256, and unpack it to a folder you are allowed to create and the sandbox accounts can read and
run. On the tested machine a new `C:\Tools\PowerShell\7` worked, because it inherited read-and-run access
for all users from `C:\` (no admin needed there); `%LOCALAPPDATA%\Programs` did not. Check it with
`codex sandbox -- <folder>\pwsh.exe -Version`, then name that path in PLAN or TASK; PATH can stay as it
is. Only the zip was tested; the MSI (it installs to `C:\Program Files`) is an untested alternative -
run the same check first.

Use a finisher for the commit to the project's protected repository and for any proof your
sandbox checks show cannot run. The recorded WSL command and github.com HTTPS request failed;
Docker daemon access was not tested. Choose one:
- **Codex drafts, a finisher commits** (recommended; the sandbox stays on). The worker proves the
  draft and says so in TASK.md; the human or a host agent reviews `git diff`, commits it in the
  same clone, and offers that commit for review.
- **A builder that commits and proves itself:** use Claude Code as the worker, with Codex
  reviewing. That is the pairing tested most.
- `-Sandbox danger-full-access`: an explicit security decision for you (no containment at all),
  best kept to disposable or well-backed-up checkouts.

For an interactive Codex worker, have it run
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
