# Looper

A tiny, model-agnostic worker/reviewer handoff built from ordinary files - informally, a boring
little mailbox for independent AI agents.

One agent does the work. A second, independent agent answers its requests: reviews, tests,
research, verification or other cross-model help. They talk through a handful of readable files in
a local folder, so you don't carry messages between them, and the job survives any session
crashing, compacting or being replaced.

Looper was extracted from a real, long-running worker/reviewer workflow on a separate private
project, then rebuilt as a standalone project and independently tested - including by using
Looper to review its own development ([docs/history.md](docs/history.md),
[docs/testing.md](docs/testing.md)). Claude Code and Codex were the first tested pair, not the
architecture: any capable agent can take either role.

```text
worker --HANDOFF.md--> second agent --REVIEW.md--> worker --> ... --> PASS + FINAL_REPORT = done
```

```text
.looper/
  CONTEXT.md        what this task is and what to read (start here after any restart)
  PLAN.md           outcome, context, boundaries, proof, escalation
  TASK.md           shared live working memory
  EXCHANGE/
    HANDOFF.md      the worker's current request
    REVIEW.md       the answer (reviews: Verdict PASS / REPAIR / BLOCKED)
  HISTORY/          every exchange, numbered
  WATCHERS/         wake-up notes, locks, logs
  FINAL_REPORT.md   closeout
```

## What it is useful for

- Claude Code writes code and Codex (or Grok through OpenCode) independently reviews it - or the other way round.
- A local model (for example Qwen through OpenCode or Claude Code + Ollama) gives a cheap second opinion.
- One agent researches or fetches something the worker cannot reach.
- Independent test verification, comparison, or an alternative line of reasoning.
- A second opinion on an important checkpoint: two reviewers, two task folders, one combined answer.
- Work that continues after either session disappears.

## Quick start

Both agents must run somewhere with local file access (a CLI agent, or a desktop app with local
file access); an ordinary browser chat cannot reach local files. The worker reads and writes your
project; the second agent only needs to read it and write its answer in the task folder. The
Windows examples use `C:\Projects\Looper` and PowerShell; macOS/Linux is shown after the steps.

1. **Get Looper** - download a release, or clone it and update it like any git repository:

   ```text
   git clone https://github.com/shedstalker/looper C:\Projects\Looper
   ```

2. **Start the worker.** Open your worker agent (Claude Code, Codex, OpenCode, ...) in your project
   and tell it:

   ```text
   Use Looper for this task. Looper is at C:\Projects\Looper - read its prompts/worker.md.
   Task: <what you want done>.
   ```

   It creates `.looper/` in your project, fills PLAN and TASK, starts work, and gives you a
   one-line prompt for the second agent. (With the [Agent Skill](#as-an-agent-skill) installed,
   "Use Looper for this task: ..." is enough.)

3. **Give the second agent that line.** How long it keeps going depends on how you run it:
   - **Manually prompted** (any agent): it answers the request that is due now and stops. Give it
     the same line again whenever the worker publishes a new handoff.
   - **Interactive and waiting** (an agent that can run background commands and be woken when they
     finish, such as Claude Code): add "then keep waiting: run the Looper helper's `wait` for the
     reviewer role in the background and answer whenever something is due". It then answers each
     new handoff by itself. (Looper's own development used this for the worker role; the reviewer
     role works the same way but has not been separately tested.)
   - **Headless driver** (no chat window): the driver waits on the files, starts the agent for each
     due handoff, and exits when the task is done:

     ```powershell
     pwsh -File C:\Projects\Looper\drivers\codex\run.ps1 -Loop <project>\.looper
     ```

     Three runtimes have drivers: Claude Code (`drivers\claude-code\run.ps1`), Codex (above) and
     OpenCode (`drivers\opencode\run.ps1 -Model <provider/model>`, the route for Grok, local
     models and other providers). Drivers need PowerShell 7 (`pwsh`). [Pick a
     runtime](drivers/README.md#pick-a-runtime) shows which models have actually passed a
     Looper handoff, plus sign-in, cost and permission boundaries.

4. **Check progress** at any time. `status` only reads the files and prints whose move it is
   (`NEXT: worker`, `reviewer` or `done`); it never starts an agent:

   ```powershell
   pwsh -File C:\Projects\Looper\tools\looper.ps1 status <project>\.looper
   ```

   `NEXT: done` plus `FINAL_REPORT.md` means finished. (Windows without PowerShell 7:
   `powershell -ExecutionPolicy Bypass -File ...`.)

5. **Afterwards** the folder is the record. `clean` removes leftover runtime files (locks, session
   ids, drafts); keep the folder, or pack it and delete it. A later session on the same task simply
   continues the same folder.

**macOS / Linux.** Clone Looper anywhere and use the POSIX helper; only the optional drivers need
PowerShell 7:

```sh
git clone https://github.com/shedstalker/looper ~/Looper
cd ~/my-project
# In your worker agent: "Use Looper for this task. Looper is at ~/Looper - read its prompts/worker.md. Task: ..."
sh ~/Looper/tools/looper.sh status .looper                 # whose move is it? (reads only)
pwsh -File ~/Looper/drivers/codex/run.ps1 -Loop .looper    # optional headless second agent
```

## What has been tested - and what hasn't

"Offered by a runtime" is not the same as "has passed a real Looper handoff". This table only
counts the second.

| Runtime (driver) | Passed real Looper handoffs | Offered, not tested with Looper |
|---|---|---|
| **Claude Code** | Claude, as worker and reviewer; Qwen through Ollama (64k context) | other models it can reach |
| **Codex CLI** | GPT (`gpt-6-sol`, `gpt-6.1-sol`), as reviewer many times and as worker | local models via `--oss`: tried, **failed** (the model could not use Codex's tools) |
| **OpenCode** | Grok, as reviewer and worker (`xai/grok-4.7` requested with a SuperGrok sign-in; OpenCode does not report the model that answered); Qwen through Ollama (one review) | Gemini, and everything else `opencode models` lists |
| Any other agent | not tested; the by-hand protocol it would follow was tested with all scripts removed (Claude and Codex) | its own |

- **Checks without models:** 48 acceptance checks. Every check that applies passes on Windows
  (PowerShell 7 and 5.1, Git Bash `sh`) and Linux (Docker: `pwsh`, `dash`); a few are
  platform-specific and skip elsewhere ([details](docs/testing.md#deterministic-suite---testsacceptanceps1)).
- **Live runs:** real, separate agents answering real handoffs, including repairs, crashes,
  restarts, resumed and fresh sessions, two reviewers on one checkpoint, and three loops running
  at once in real use.
- **Limits:**
  - Looper is a mailbox, not a sandbox: the runtime's own permissions are the boundary, and
    OpenCode's are rules rather than a sandbox.
  - The longest runs are under an hour.
  - macOS has not been run.
  - Local models make a useful second opinion but are not yet trusted as the only reviewer.
  - The Skill upload in ChatGPT has not been tried.

Everything, including what failed: [docs/testing.md](docs/testing.md).

## How it works

- The worker publishes a request (`HANDOFF.md`); the second agent answers (`REVIEW.md`) with
  a `Handoff:` line naming the exact handoff it answered (plus `Verdict:` for reviews).
- **A handoff stays due until an answer naming it is published.** Whose move it is gets
  recomputed from the files every time, so an agent that crashes or loses its runner simply
  leaves the work due for the next attempt, and restarts need no recovery step.
- Publishing is atomic (temp file + rename) and logged to HISTORY. Stale answers are refused;
  unchanged handoffs stay quiet.
- For files outside Git (a document, an export), `publish ... handoff -Attach <file>` snapshots
  them into HISTORY and lists each one's size and SHA-256 in the handoff. The reviewer reads the
  snapshot, so a file it can't reach, or one still syncing, doesn't matter.
- Wake-ups only move attention; they never judge work or edit source.
- The whole protocol also works by hand, with no scripts at all ([docs/contract.md](docs/contract.md)).
- Looper grants no authority. A PASS is evidence about an exact candidate, not permission to
  merge, deploy or write anywhere PLAN doesn't allow.

## What Looper is not

Not a model, a gateway, an agent swarm or an orchestration service; no database, queue, daemon or
MCP server. The agent runtime provides the tools, the model provides the reasoning, Git stays the
source of truth, and Looper provides the durable, bounded handoff.

## Design ideas

- **Agent as file.** The model session is disposable working context; the files are the durable,
  interpretable state of the work. Another capable session - or a different model - can enter the
  folder, read it, understand where the job stands and continue. Looper does not try to move hidden
  context windows or provider-specific reasoning between models; it writes down what needs to
  survive. That is what makes cross-model use straightforward.
- **Inspired by ICM.** Looper was influenced by the Interpretable Context Methodology (ICM),
  associated with Jake Van Clief and David McDermott: the information environment itself can be
  structured so that a capable agent orients itself from it - the filesystem is part of the
  interface, not just storage. Looper applies that idea to a small worker / independent-responder
  handoff; it did not invent file-based context or Markdown state.
- **The name.** The work forms a loop - worker, handoff, independent second agent, answer, repair
  or continue, loop closed. It is also a light nod to the film *Looper*: a job turns up for an
  independent operator to deal with, and the loop gets closed.

More in [docs/history.md](docs/history.md): origins, lineage and the lessons behind each design choice.

## Releases

- **v0.1.0 - Level 1 Basic** and **v0.2.0 - Level 1 Deluxe**: private development releases.
- **v0.2.1 - Level 1 Deluxe**: the first public release (documentation only).
- **v0.3.0 - Level 1 Deluxe**: the OpenCode driver (a third runtime route), attachments for
  files outside Git, fixes found in real use, current model guidance.

Nothing beyond Level 1 is implemented here. What each version delivered: [CHANGELOG.md](CHANGELOG.md).

## Learn more

| | |
|---|---|
| [CONTEXT.md](CONTEXT.md) | Router for agents working on or with Looper |
| [docs/contract.md](docs/contract.md) | The Level 1 contract: files, identity, due rule, publishing, lifecycle |
| [prompts/](prompts/) | Worker and second-agent (reviewer) role instructions |
| [drivers/](drivers/README.md) | Picking a runtime (Claude Code, Codex, OpenCode); running each role visible, headless or manual; model and effort; sessions; local models |
| [drivers/others.md](drivers/others.md) | Other agent CLIs we checked, and why only three runtimes have drivers |
| [integrations/host-snippet.md](integrations/host-snippet.md) | A paragraph to paste into another system's prompts so its agents ask for review at the right moments |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Reporting a problem, proposing a change, running the checks |
| [examples/hello-looper](examples/hello-looper/) | A complete real run |
| [docs/testing.md](docs/testing.md) | What has been proven, and how - including what failed |

Run the checks: `pwsh -File tests/acceptance.ps1` (no model calls; add `-Helper sh` for the sh edition).

## As an Agent Skill

Optional convenience; the folder itself remains the reference. Install Looper as a skill and just
say "use Looper for this task". One generated package targets Claude Code, Codex and ChatGPT
surfaces that support installing or uploading skills:

- tested live: Claude Code (project skill) and Codex (`.agents/skills`);
- validated: the package passes the official Codex skill validator;
- not yet exercised: installing or uploading it in ChatGPT.

```powershell
pwsh -File integrations/skill/build.ps1 -Out ~/.claude/skills/looper   # Claude Code
pwsh -File integrations/skill/build.ps1 -Out ~/.agents/skills/looper   # Codex
pwsh -File integrations/skill/build.ps1                                 # dist/looper-skill.zip for upload
```

The skill is a generated copy of this repository's files, never a separate version.

## Issues and changes

`shedstalker/looper` is the public release and product repository. Development and release
qualification happen separately, in the maintainers' development repository. Issues and
suggestions are welcome; proposed code changes are treated as proposals, incorporated through
that development process, and come back in a reviewed release. Open an issue at
[github.com/shedstalker/looper/issues](https://github.com/shedstalker/looper/issues); how to report a
problem so it can actually be fixed: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT - see [LICENSE](LICENSE). Copyright (c) 2026 Nicholas Atkins.
