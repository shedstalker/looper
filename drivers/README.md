# Drivers - launching and waking each role

The Looper contract (`docs/contract.md`) never mentions a provider. Everything
provider-specific lives here: how to launch a role, which model it uses, and how it gets woken
when it has due work. A driver moves attention only; it never judges work, edits source or
grants authority. Every choice below is a runtime choice: the same task folder works whether an
agent is visible, headless or started by hand, and none of it is needed to operate Looper manually.

## Pick a runtime

The runtime is the agent's body: it reads and writes files and runs commands. The model it runs
is the brain. Looper only needs a runtime that can reach the task folder and run the helper.

| Runtime | Models (as the runtime offers them) | Passed Looper handoffs with | Access boundary | Start a headless role |
|---|---|---|---|---|
| **Claude Code** | Claude; local via Ollama | Claude; Qwen via Ollama (64k context) | tool allow-list; includes `pwsh`/`sh`, so not containment | `claude-code/run.ps1 -Loop <folder>` |
| **Codex CLI** | OpenAI models | GPT (`gpt-6-sol`, `gpt-6.1-sol`), heavily; local via `--oss` **failed** | OS sandbox (`workspace-write`): the reviewer can write only in the task folder | `codex/run.ps1 -Loop <folder>` |
| **OpenCode** | many providers: xAI, Google, Ollama, ... | Grok (`xai/grok-4.7` requested; SuperGrok); Qwen via Ollama (once). Others **untested** | rules only, no sandbox | `opencode/run.ps1 -Loop <folder> -Model <provider/model>` |
| **Any other agent** | its own | by hand (E6) | the agent's own | give it the one-line prompt |

Sign-in, cost and the exact permissions are in each driver's README. "Offered by the runtime"
is not "passed a Looper handoff": run one review round before relying on a new model. For
independence, give the reviewer a different model from the worker.

## Pick how each role runs

| Role runs as | How it is woken | Idle model cost |
|---|---|---|
| **Visible interactive session** you keep open (Claude Code, Codex TUI, any agent) | The agent itself runs the helper's `wait <folder> -For <role>` in the background and acts when it returns (Claude Code does this well) | none |
| **Headless driver** | `drivers/<provider>/run.ps1 -Loop <folder> -Role <role>` waits on the files, runs the CLI with a one-line prompt, retries if nothing was published | none |
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
Nothing is lost when it closes: every attempt, failure and give-up is in `WATCHERS/<role>.log`
(and the last output in `<role>-last.txt`/`.err`). To learn the answer, use `wait -For worker`,
not the window.

Window management (opening terminals, attaching to apps) is deliberately not part of Looper.
To watch or take over a headless session, run the printed command in any terminal, for example
`codex resume <id>` or `claude --resume <id>` (only while the driver is not running it).

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
| `opencode/run.ps1` | `-Model xai/grok-4.7` | `-Variant <name>` | nothing - requested only |

A runtime may refuse or override a request (seen in testing: an unsupported Claude model was
rejected; `--ignore-user-config` silently turned Codex's sandbox read-only). Read the
"runtime reported" part, not the request.

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

## Local models

`Looper -> existing agent runtime -> local model`. Looper itself has no model code.

- **Claude Code + Ollama** (tested, works): `claude-code/run.ps1 -Local <ollama-model>` points
  Claude Code at Ollama's Anthropic-compatible API. The model must be served with a large
  context window - Claude Code's prompt is big, and at Ollama's default 32k the request was lost
  ("no user query found" / "I'm ready"). Make a 64k variant once:
  `ollama create qwen36-64k -f Modelfile` with `FROM qwen3.6:27b` and `PARAMETER num_ctx 65536`.
- **OpenCode + Ollama** (worked once with the plain `opencode run` command, E10; the driver passes
  the same `-Model ollama/<model>`): configure Ollama as an OpenCode provider (see `others.md`).
- **Codex + Ollama** (`codex/run.ps1 -Local <model>`, i.e. `--oss`): wired, but in testing the
  Qwen 3.6/3.8 models could not drive Codex's tools (they called a non-existent `read_file`),
  so nothing was published. The attempt failed safely (work stayed due).

Treat a local model as a useful second opinion or helper, not as the only reviewer of
consequential work, until your own runs show otherwise.

## Provided drivers

- [`generic/`](generic/README.md) - `agent-loop.ps1`, the shared wait/lock/run/retry/session loop.
- [`claude-code/`](claude-code/README.md) - Claude Code (headless or interactive; local via Ollama).
- [`codex/`](codex/README.md) - Codex CLI (headless `codex exec`), and Codex app scheduled tasks.
- [`opencode/`](opencode/README.md) - OpenCode (headless `opencode run`): Grok, local and other models.
- [`others.md`](others.md) - other agent CLIs checked, and why they are or are not included.

## A second opinion on the same checkpoint

Level 1 has one reviewer and one `REVIEW.md` per task folder. To get two independent answers
(say Codex and Grok) on the same checkpoint, give the second reviewer **its own task folder**:

1. Create it with `new <other folder> -Project <project>`, for example `<project>/.looper-second`
   or a folder outside the project.
2. Copy PLAN, and publish the same handoff text there.
3. Run both reviewers at once, one per folder.

Started together, neither has the other's answer to read. On one machine this is independence by
timing and instruction, not by access; E15 used a container for strict isolation. The worker reads both reviews and publishes one combined next
handoff in the main task. The second folder is then closed or discarded. Tested in E15: each
reviewer took about 1.5 minutes, both found the same defect, and each found extra cases. Useful
for consequential checkpoints; not needed routinely.

## Other runtimes and models

Looper keeps drivers for three runtimes only: Claude Code, Codex and OpenCode. A new model or
provider goes through OpenCode (`-Model provider/model`) where OpenCode supports it cleanly;
if it does not, that limit is documented rather than worked around. Any other agent can still
take either role by hand with the one-line prompt. `generic/agent-loop.ps1` is the shared loop
the three drivers are built on, not an invitation to add more.
