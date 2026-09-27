# Drivers - launching and waking each role

The Looper contract (`docs/contract.md`) never mentions a provider. Everything
provider-specific lives here: how to launch a role, which model it uses, and how it gets woken
when it has due work. A driver moves attention only; it never judges work, edits source or
grants authority. Every choice below is a runtime choice: the same task folder works whether an
agent is visible, headless or started by hand, and none of it is needed to operate Looper manually.

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

Window management (opening terminals, attaching to apps) is deliberately not part of Looper.
To watch or take over a headless session, run the printed command in any terminal, for example
`codex resume <id>` or `claude --resume <id>` (only while the driver is not running it).

## Provider, model and effort

Choose per role on the driver's command line. The driver logs what you **requested** and, separately,
what the runtime **reported** it used, in `WATCHERS/<role>.log`:

```text
... requested: model=gpt-6-sol effort=high sandbox=workspace-write
... attempt published (exit 0, session 01a0..., runtime reported: model=gpt-6-sol effort=high provider=openai sandbox=workspace-write tokens=12,118)
```

| Driver | Model | Reasoning effort | Verified from the runtime's own output |
|---|---|---|---|
| `codex/run.ps1` | `-Model gpt-6-sol` | `-Effort low…xhigh` | model, effort, provider, sandbox, tokens (header) |
| `claude-code/run.ps1` | `-Model claude-opus-5` | `-Effort low…max` | model only - Claude Code does not report effort |

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

## Local models

`Looper -> existing agent runtime -> local model`. Looper itself has no model code.

- **Claude Code + Ollama** (tested, works): `claude-code/run.ps1 -Local <ollama-model>` points
  Claude Code at Ollama's Anthropic-compatible API. The model must be served with a large
  context window - Claude Code's prompt is big, and at Ollama's default 32k the request was lost
  ("no user query found" / "I'm ready"). Make a 64k variant once:
  `ollama create qwen36-64k -f Modelfile` with `FROM qwen3.6:27b` and `PARAMETER num_ctx 65536`.
- **Codex + Ollama** (`codex/run.ps1 -Local <model>`, i.e. `--oss`): wired, but in testing the
  Qwen 3.6/3.8 models could not drive Codex's tools (they called a non-existent `read_file`),
  so nothing was published. The attempt failed safely (work stayed due).

Treat a local model as a useful second opinion or helper, not as the only reviewer of
consequential work, until your own runs show otherwise.

## Provided drivers

- [`generic/`](generic/README.md) - `agent-loop.ps1`, the shared wait/lock/run/retry/session loop.
- [`claude-code/`](claude-code/README.md) - Claude Code (headless or interactive; local via Ollama).
- [`codex/`](codex/README.md) - Codex CLI (headless `codex exec`), and Codex app scheduled tasks.
- [`others.md`](others.md) - other agent CLIs checked, and why they are or are not included.

## Adding a provider

Create `drivers/<provider>/` with a README and, if the provider has a non-interactive CLI, a
`run.ps1` of about 50 lines that builds its command lines and calls `generic/agent-loop.ps1`
(see `codex/run.ps1`). It needs: prompt on stdin, a working directory, the ability to run a
helper and write in the task folder. Optional: a resume command plus the text the CLI prints
when a session cannot be resumed; a session-id pattern; patterns for what the runtime reports.
Nothing outside `drivers/<provider>/` changes.
