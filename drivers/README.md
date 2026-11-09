# Drivers - launching and waking each role

The normative [Looper contract](../docs/contract.md) never mentions a provider. Everything
provider-specific lives here: how to launch a role, which model it uses, and how it gets woken
when it has due work. A driver moves attention only; it never judges work, edits source or
grants authority. Every choice below is a runtime choice: the same task folder works whether an
agent is visible, headless or started by hand, and none of it is needed to operate Looper manually.

References here to `docs/testing.md`, `docs/decisions.md` and their E/D records refer to the
development repository; the generated Skill ships only `docs/contract.md`.

## Pick a runtime

The runtime is the agent's body: it reads and writes files and runs commands. The model it runs
is the brain. Looper only needs a runtime that can reach the task folder and run the helper.

| Runtime | Models (as the runtime offers them) | Passed Looper handoffs with | Access boundary | Start a headless role |
|---|---|---|---|---|
| **Claude Code** | Claude; local via Ollama | Claude; Qwen via Ollama (64k context) | tool allow-list; includes `pwsh`/`sh`, so not containment | `claude-code/run.ps1 -Loop <folder>` |
| **Codex CLI** | OpenAI models | GPT (`gpt-6-sol`, `gpt-6.1-sol`), heavily; local via `--oss` **failed** | OS sandbox (default `workspace-write`: the reviewer can write only in the task folder; `-Sandbox config` leaves it to the caller) | `codex/run.ps1 -Loop <folder>` |
| **Any other agent** | its own | by hand (E6) | the agent's own | give it the one-line prompt |

Sign-in, cost and permissions are in the runtime sections below. "Offered by the runtime"
is not "passed a Looper handoff": run one review round before relying on a new model. For
independence, give the reviewer a different model from the worker.

**For work, not only review:** Claude Code as the worker can edit, prove and commit; a Codex
worker on Windows cannot commit ([Windows builder limits](#windows-builder-limits)).

## Pick how each role runs

| Role runs as | How it is woken | Idle model cost |
|---|---|---|
| **Visible interactive session** you keep open (Claude Code, Codex TUI, any agent) | The agent itself runs the helper's `wait <folder> -For <role>` in the background and acts when it returns (Claude Code does this well) | none |
| **Headless driver** | `drivers/<provider>/run.ps1 -Loop <folder> -Role <role>` waits on the files, runs the CLI with a one-line prompt, retries if nothing was published (with `-Once`, makes at most one attempt) | none |
| **Headless, but watchable** | the same driver with `-Show`: the agent's live output streams into the driver's terminal, and after each attempt it prints the command to open that session interactively | none |
| **Scheduled heartbeat** (an app's scheduler, Task Scheduler, cron) | every N minutes the agent gets the one-line prompt; it runs `status` and stops if nothing is due | one small call per tick |
| **Manual** | you give the agent the one-line prompt when you want it to check | none |

The one-line role prompt, printed by the helper's `new`, is all any wake-up ever sends:

```text
You are the REVIEWER for the Looper task at <folder>. Read <folder>/CONTEXT.md and follow the reviewer route.
```

Starting a driver *from an agent* that has no terminal of its own: open one for the driver, but
without `-NoExit`, so the window closes when the driver ends, e.g.
`Start-Process pwsh -ArgumentList '-NoProfile', '-File', '"<looper>/drivers/codex/run.ps1"', '-Loop', '"<folder>"', '-Show'`
(the inner quotes matter: `Start-Process` joins the arguments with spaces, so a path with a space
would otherwise split).
Attempts and output are saved under `WATCHERS/` (see Shared loop and access below).

Window management (opening terminals, attaching to apps) is deliberately not part of Looper.
To watch or take over a headless session, run the printed command in any terminal, for example
`codex resume <id>` or `claude --resume <id>` (only while the driver is not running it).

## Host-launched reviewer (watcher)

After `new`, start the reviewer outside the worker's sandbox, without `-Once`:

```powershell
pwsh -NoProfile -File drivers/codex/run.ps1 -Loop <folder> -Role reviewer -Session fresh -IdleExitMinutes 60
```

It waits without model calls and starts a fresh attempt for each new handoff. Unpublished work
stays due and is retried up to `-MaxFailures`. `-IdleExitMinutes` bounds an orphan's idle time
since start or the last attempt; 0 (default) never exits for idleness. Stop the watcher by its
PID (logged at start), the holder of `WATCHERS/<role>.lock`: `kill -TERM <pid>` on Unix
(PowerShell 7.2+), or `taskkill /T /F /PID <pid>` on Windows to stop the whole tree.

| Exit | Meaning |
|---|---|
| 0 | Task done, idle limit reached, or `-Once` published |
| 4 | Another driver holds this role's lock |
| 5 | Watcher reached `-MaxFailures` consecutive unpublished attempts |
| 6 | `-Once` attempt ended without publishing; work stays due |
| 7 | `-Once` found nothing due for this role |

`-Once` never waits or retries; a task already done exits 0 and cleans runtime files.

## Provider, model and effort

Defaults belong to the runtime, not to Looper: set them once in Codex's `config.toml` (`model`,
`model_reasoning_effort`) and Claude Code's `settings.json` (`model`), and every driver started
without `-Model` follows them. Current choices (September 2026; the Astra comparison was reported
from real use on another project, not measured in `docs/testing.md`):

- Codex `gpt-6.1-sol` for reviews: `high` for checkpoints, `-Effort xhigh` for gates and the
  final cumulative review.
- `gpt-6-astra` at `xhigh` only as an optional second opinion (a second task folder, D25) on the
  final gate before merging or installing. It cost about five times as much and was not sharper.
- Claude Opus 5.5 (`claude-opus-5-5`).

Models are renamed and retired often, so check the provider's list when a run fails on a model
name.

To override for one role, choose on the driver's command line. The driver logs what you **requested** and, separately,
what the runtime **reported** it used, in `WATCHERS/<role>.log`:

```text
... requested: model=gpt-6.1-sol effort=high sandbox=workspace-write
... attempt published (exit 0, session 01a0..., runtime reported: model=gpt-6.1-sol effort=high provider=openai sandbox=workspace-write tokens=12,118)
```

| Driver | Model | Reasoning effort | Verified from the runtime's own output |
|---|---|---|---|
| `codex/run.ps1` | `-Model gpt-6.1-sol` (`gpt-6-astra` as an optional final second opinion) | `-Effort low…ultra` (Codex validates; values vary by model) | model, effort, provider, sandbox, tokens (header) |
| `claude-code/run.ps1` | `-Model claude-opus-5-5` | `-Effort low…max` (Claude Code validates) | model only - Claude Code does not report effort |

A runtime may refuse or override a request (seen in testing: an unsupported Claude model was
rejected; `--ignore-user-config` silently turned Codex's sandbox read-only). Read the
"runtime reported" part, not the request.

`-Extra` in both wrappers splits on whitespace. To keep a value with spaces together,
quote the **whole token** with single or double quotes inside the string, for example
`-Extra:"--add-dir 'C:\work folder'"`. Within such a token the other quote character is literal
(e.g. `-Extra:'-c ''key="value"'''`); use whole-token quoting for `key=value` too.
Within the resulting string, backslash-escaping or doubling a matching quote is unsupported.

## Sessions: resume by default, fresh on request

`-Session resume` (default) continues the role's previous session across handoffs, so the agent
keeps what it already read. The session id is kept in `WATCHERS/<role>.session` - runtime state
only. If the runtime says that session is gone (deleted chat, cleared history), the driver
cold-starts a fresh session from the task folder in the same attempt. An attempt that simply
publishes nothing keeps its session and is retried normally.

`-Session fresh` starts every attempt in a new session: maximum independence, no carried-over
context. Deleting `*.session` files (or `looper clean`) is always safe.

Measured (docs/testing.md, E8): on three identical review rounds, resumed Codex reviews used
roughly a third fewer tokens per follow-up and were somewhat faster, with the same verdicts.

A resumed session also carries everything it read before, so its cost per round climbs. In real
use, a resumed Codex reviewer used 105k, 135k and 161k tokens over three rounds. Rule of thumb:
resume while the rounds build on each other, then start the final cumulative review (or any
round after a long loop) with `-Session fresh` (and `-Effort xhigh`, above). The final review
reads the whole outcome anyway, and a fresh reader is also more independent. Each attempt's tokens are in
`WATCHERS/<role>.log` (as the runtime reports them).

## A second opinion on the same checkpoint

Level 1 has one reviewer and one `REVIEW.md` per task folder. To get two independent answers
(say Codex and Claude) on the same checkpoint, give the second reviewer **its own task folder**:

1. Create it with `new <other folder> -Project <project>`, for example `<project>/.looper-second`
   or a folder outside the project.
2. Copy PLAN, and publish the same handoff text there.
3. Run both reviewers at once, one per folder.

Started together, neither has the other's answer to read. On one machine this is independence by
timing and instruction, not by access; E15 used a container for strict isolation. The worker reads both reviews and publishes one combined next
handoff in the main task. The second folder is then closed or discarded. Tested in E15: each
reviewer took about 1.5 minutes, both found the same defect, and each found extra cases. Useful
for consequential checkpoints; not needed routinely.

## Shared loop and access

All wrappers require PowerShell 7. The reviewer runs in the task folder and reads the project;
the worker runs in the project with access to the task folder and Looper home. Role rules
alone do not contain shell commands: Claude Code uses an allow-list and Codex uses an
OS sandbox. Choose access deliberately; Looper grants no authority.
For strict isolation, use a container or VM with only the intended files mounted (E14-E15).

`generic/agent-loop.ps1` supplies the shared wait/lock/run/retry/session machinery. Its interface
is useful for understanding the wrappers, not an invitation to add more supported CLIs:

```powershell
pwsh -File drivers/generic/agent-loop.ps1 -Loop <folder> -Role reviewer -Exe <cli> -Arguments <args...>
```

The loop holds `WATCHERS/<role>.lock`, sends the one-line prompt on stdin and re-reads the
files after each attempt. A CLI exit alone never settles work. Failures retry after
`-RetrySeconds`; consecutive unpublished attempts count toward `-MaxFailures` (default 3).
`-AttemptTimeoutMinutes` and `-IdleExitMinutes` accept fractional minutes. On timeout or shutdown,
the active child tree is killed and given up to 30 seconds to exit. Unix SIGTERM cleanup needs
PowerShell 7.2+ (.NET 6+); the generic loop retains a tested Windows PowerShell 5.1 path.

Wrapper hooks and substitutions:

- `-Arguments` accepts `{LOOP}`, `{PROJECT}`, `{HOME}`; `-ResumeArguments` also accepts `{SESSION}`.
- `-SessionPattern`: first capture group is the session id; `-ResumeFailurePattern` identifies
  an explicitly missing session, the only condition that triggers a cold start.
- `-Requested` and `-Report 'name=regex'` keep requested and runtime-reported settings separate.
- `-AttachHint 'cli resume {SESSION}'` prints the takeover command; `-Show` streams output.
- `-BeforeAttempt {scriptblock}` prepares runtime access without changing file content; Codex
  uses it to re-own sandbox-created files on Windows.

Logs and last output live under `WATCHERS/`: `<role>.log` records starts, results, failures,
give-ups, requested/reported settings and any reported tokens; `<role>-last.txt` / `.err` hold
the last attempt's output. The answer itself is `EXCHANGE/REVIEW.md`; `wait -For worker` only says when it is due.

## Claude Code

Checked with Claude Code 2.1.278 (September 2026); `claude-opus-5-5` needs 2.1.280 or newer.
These are recorded CLI facts, not a promise about later versions.

### Interactive worker and permissions

Start Claude Code in the project and say: "Use Looper for this task. Looper is at
<looper-home> - read its prompts/worker.md. Task: ...". After each
handoff, run `wait <folder> -For worker` as a **background** command: Claude Code re-invokes the
session when it returns. Exit 3 is a quiet timeout (default 12 h); start it again. A replacement
session needs only `Continue the Looper task at <folder> as the WORKER - read its CONTEXT.md.`

Configure permissions before starting, for every folder the session and its subagents will use:

- `permissions.additionalDirectories` (or `--add-dir`) must cover **all** task folders; their
  common parent is simplest.
- With an allow-list, allow the helper and drivers, e.g. `Bash(pwsh *)`, `Bash(sh *)` or the
  `PowerShell` tool.
- In auto mode those broad interpreter rules are set aside; add a plain-language line to
  `autoMode.environment` saying the Looper helper and drivers on these task folders are intended.

Subagents inherit those rules, and permission edits reload without a restart. If a Looper
command is refused, the agent stops and asks the owner; it must never widen its own permissions.
Real subagent lanes were refused until their additional task folders were named too.

### Headless flags and access

```powershell
pwsh -File drivers/claude-code/run.ps1 -Loop <folder>                    # reviewer
pwsh -File drivers/claude-code/run.ps1 -Loop <folder> -Role worker
pwsh -File drivers/claude-code/run.ps1 -Loop <folder> -Model claude-opus-5-5 -Effort high -Session fresh -Show
```

```text
claude -p --output-format json --add-dir <looper-home>
  reviewer: --permission-mode dontAsk --add-dir <project>   (cwd = task folder)
  worker:   --permission-mode acceptEdits --add-dir <task>  (cwd = project)
  --allowedTools Read,Grep,Glob,Write,Edit,PowerShell,Bash(pwsh *),Bash(sh *),Bash(git *)
  [--model M] [--effort E] [--resume <id>]
```

`dontAsk` refuses unlisted tools instead of hanging on a prompt. Add test commands with
`-Extra:"--allowedTools 'Bash(npm test *)'"`. This is not containment: the allowed shells can
write source. Headless `claude -p` runs project hooks and MCP servers; `-Extra:"--bare"` avoids
that but requires an API key. `-Claude <path>` overrides executable discovery.

`-Show` streams output, but Claude's JSON result arrives at attempt end. Take over with
`claude --resume <id>` between attempts. `claude --bg` / `claude attach <id>` is an alternative
supervised session; the driver does not use it because it must know when each attempt finishes.

`-Local <ollama-model>` points Claude Code at Ollama's Anthropic-compatible API. Tested Qwen
worked with 64k context (E9b); Ollama's default 32k lost the request ("no user query found" /
"I'm ready"). Create a variant once with `ollama create qwen36-64k -f Modelfile`:

```text
FROM qwen3.6:27b
PARAMETER num_ctx 65536
```

## Codex CLI

Checked with codex-cli 0.158 and 0.159 (September 2026). `gpt-6.1-sol` needed 0.159; 0.158 rejected
it. The CLI is found on PATH or, on Windows, in `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`;
`-Codex <path>` overrides discovery.

### Headless flags and sandbox

```powershell
pwsh -File drivers/codex/run.ps1 -Loop <folder> -Model gpt-6.1-sol -Effort high -Show
pwsh -File drivers/codex/run.ps1 -Loop <folder> -Session fresh -Effort xhigh  # final review
pwsh -File drivers/codex/run.ps1 -Loop <folder> -Role worker
```

```text
first reviewer: codex exec --sandbox workspace-write --skip-git-repo-check [--model M] [-c model_reasoning_effort=E] --cd <task folder> -
resumed:        codex exec resume --skip-git-repo-check [...] -c sandbox_mode=workspace-write <session id> -
worker:         codex exec --sandbox workspace-write --cd <project> --add-dir <task folder> -
```

Resumed sessions do **not** retain sandbox or working directory; the driver re-applies both
(and the worker's task-folder writable root). With `-Sandbox config` it leaves sandbox selection
to the caller. `no rollout found` triggers a cold start. The runtime reports model, effort,
provider, sandbox, session and tokens. Open the session with `codex resume <id>` between attempts.

Default `workspace-write` makes only the task folder writable for a reviewer. It can read the
project and run read-only checks, but on Windows a synced Google Drive folder was unreadable;
attach such files with `publish ... handoff -Attach <file>` so it reads a local snapshot.
For writable test/build space, use config accepted by both fresh and resumed runs:
`-Extra:"-c sandbox_workspace_write.writable_roots=['C:\scratch']"` (tested on both).
`codex exec resume` accepts only some options (`-c`, `-m`, ...), not `--add-dir`, `--oss` or
`--profile`; prefer `-c key=value` in `-Extra` or a `-Codex` wrapper that adds those settings.

`-Sandbox config` emits no sandbox selector, `--add-dir` or `writable_roots`: the caller grants the
task folder, on fresh and resumed runs alike. Use it with caller-owned permission settings, e.g. a
credential-deny profile. In the default modes a resumed run puts `-c sandbox_mode=...` after
`-Extra`, so `-Extra` cannot change the sandbox there (intended); `-Sandbox config` is the way to own it.
`-Sandbox danger-full-access` removes containment entirely; it is the owner's explicit choice,
best limited to disposable or backed-up checkouts. A runtime can override requests: in testing,
`--ignore-user-config` silently selected read-only access. Check the reported settings.

`codex review --commit <sha>` is a useful reviewer check; Looper launches `codex exec` because
the role must also read PLAN/TASK and publish REVIEW.md. `-Local <ollama-model>` uses `--oss` and
always starts fresh because resume cannot select that provider. Qwen 3.6/3.8 could not drive
Codex's tools (called a non-existent `read_file`); work stayed due (E9a).

### Windows builder limits

Measured with codex-cli 0.159 on 2026-09-30 (E20). Probe tools without a model using
`codex sandbox -- <full path to program> --version` before relying on them.

| Action in `workspace-write` | Observed result |
|---|---|
| Edit project files; Windows PowerShell 5.1 | works |
| PowerShell 7 official zip in a folder the sandbox accounts can read | works; suite 50/50 from a granted scratch folder; `C:\Tools\PowerShell\7` also starts |
| Microsoft Store `...\WindowsApps\pwsh.exe` | cannot start: "Access is denied" |
| Full paths to git (read), Git Bash `C:\Program Files\Git\bin\sh.exe`, `gh --version` | start; gh warns it cannot read its config |
| Tested executables under `%LOCALAPPDATA%\Programs` (PowerShell 7, OpenCode, Ollama, Docker Desktop's docker.exe) | cannot start: separate `CodexSandboxUsers` accounts lacked read access on this machine |
| Network | off by default; with `-c sandbox_workspace_write.network_access=true`, localhost Ollama answered, one github.com HTTPS request failed (`SEC_E_NO_CREDENTIALS`) |
| `wsl -l -q` | refused; Docker daemon access was not tested |
| `git commit` in the existing project repo | refused; `.git` remains read-only even in `writable_roots`; `--add-dir <repo>/.git` was also refused with 0.158 on 2026-09-27 |
| New repository created in a writable folder | can commit, but it is not the project repo |
| `taskkill.exe` | refused even for own children; `Stop-Process` works on them |

For PowerShell 7 proofs, download the official `PowerShell-<version>-win-x64.zip` from
`github.com/PowerShell/PowerShell/releases`, verify SHA-256 and unpack where the sandbox accounts
can read and run it. `C:\Tools\PowerShell\7` inherited suitable access from `C:\` on the tested
machine (no admin needed); `%LOCALAPPDATA%\Programs` did not. Verify with
`codex sandbox -- <folder>\pwsh.exe -Version`, then name the path in PLAN or TASK; leave PATH alone.
Only the zip was tested. The MSI under `C:\Program Files` is an untested alternative; probe first.

Recommended: **Codex drafts and proves, a finisher commits**. TASK records the proof; a human or
host agent reviews `git diff`, commits in the same clone, and offers that commit for review.
The finisher also runs proofs the sandbox cannot. Claude Code as worker with Codex reviewing is
the most-tested pairing when the worker must commit itself.

### Interactive worker or scheduled reviewer

An interactive Codex worker runs `looper.ps1 wait <folder> -For worker` as a blocking command
between checkpoints. A replacement needs only the continuation prompt used above.
The Codex/ChatGPT desktop app can schedule the one-line reviewer prompt, even in an existing
chat. Each idle tick costs a small call; the reviewer runs `status` and stops if nothing is due.
Never put task details, candidate hashes or procedure into the schedule: they go stale.

## Other runtimes and models

Only Claude Code and Codex get drivers (D24, D28). The OpenCode driver was removed in v0.4.1;
its tested runs (Grok, local Qwen: E10, E14-E17) stay in the testing record. Any other model or
file-capable agent can take either role by hand with the one-line prompt; shell access helps it
call a helper.

Surveyed 2026-09-27 from then-current documentation, not live Looper proof:

| CLI | Headless; resume | Model / effort | Access and limitations |
|---|---|---|---|
| Qwen Code | `-p`, stdin; `--resume <id>` | `-m` / none | Gemini fork, `--yolo` or `--approval-mode`; JSON; Ollama, API key or local model |
| GitHub Copilot CLI | `-p`, stdin; `--resume=<id>` | `--model` / `--reasoning-effort` | `-C <dir>`, `--allow-all-tools`/`--allow-tool`; JSON; subscription; BYOK including local |
| Gemini CLI | `-p`, stdin; `--resume <id>` | `-m` / settings only | `--approval-mode yolo`; JSON; no Ollama; generous free tier |
| Cline CLI | `cline "<task>"`; `--id` | `-m` / `--thinking` | auto-approve default; NDJSON; Windows support unclear |

Poor fits: Aider suggests shell commands rather than reliably running the helper (no session
ids/JSON); Goose resumes by name only, has no directory flag and uses env/config permissions
(Windows through WSL/Git Bash); Pi has no permission layer or directory flag; Factory Droid and
Kimi Code need proprietary keys or have unclear headless permissions.

Local models (results: E9a, E9b, E10): use them as helpers or second opinions
until your own evidence supports trusting them alone for consequential reviews.
