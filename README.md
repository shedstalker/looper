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

- Claude Code writes code and Codex independently reviews it - or the other way round.
- A local model (for example Qwen through OpenCode or Claude Code + Ollama) gives a cheap second opinion.
- One agent researches or fetches something the worker cannot reach.
- Independent test verification, comparison, or an alternative line of reasoning.
- Work that continues after either session disappears.

## Quick start

Both agents must run somewhere that can read and write your project folder (a CLI agent, or a
desktop app with local file access); an ordinary browser chat cannot reach local files. The
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

     Claude Code instead: `drivers\claude-code\run.ps1`. Drivers need PowerShell 7 (`pwsh`); see
     [drivers/](drivers/README.md) for model, effort, sessions and local models.

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

## Releases

Looper was developed privately through v0.1.0 (Level 1 Basic) and v0.2.0 (Level 1 Deluxe).
**Public distribution begins with v0.2.1**; the earlier versions are development lineage, not
releases of the public repository.

| Version | What it is |
|---|---|
| **v0.1.0 - Level 1 Basic** (private development release) | The original, deliberately minimal protocol: one bounded job, one worker, one independent second agent, ordinary files as durable state. Proved that sessions are disposable, stale answers cannot apply to new work, and interrupted reviews leave work due. |
| **v0.2.0 - Level 1 Deluxe** (private development release) | The same protocol made comfortable for repeated real use: session resume, model and effort selection (requested vs. reported), visible/headless/manual modes, local-model routes, an Agent Skill, lifecycle cleanup and adapter hardening. |
| **v0.2.1 - Level 1 Deluxe** (first public release) | v0.2.0 with documentation prepared for public distribution; no behaviour change. |

Nothing beyond Level 1 is implemented here. Details: [CHANGELOG.md](CHANGELOG.md).

## How it works

- The worker publishes a request (`HANDOFF.md`); the second agent answers (`REVIEW.md`) with
  a `Handoff:` line naming the exact handoff it answered (plus `Verdict:` for reviews).
- **A handoff stays due until an answer naming it is published.** Whose move it is gets
  recomputed from the files every time, so an agent that crashes or loses its runner simply
  leaves the work due for the next attempt, and restarts need no recovery step.
- Publishing is atomic (temp file + rename) and logged to HISTORY. Stale answers are refused;
  unchanged handoffs stay quiet.
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

## Learn more

| | |
|---|---|
| [CONTEXT.md](CONTEXT.md) | Router for agents working on or with Looper |
| [docs/contract.md](docs/contract.md) | The Level 1 contract: files, identity, due rule, publishing, lifecycle |
| [prompts/](prompts/) | Worker and second-agent (reviewer) role instructions |
| [drivers/](drivers/README.md) | Running each role: visible, headless or manual; model and effort; sessions; local models |
| [drivers/others.md](drivers/others.md) | Other agent CLIs (OpenCode, Qwen Code, Copilot CLI, Gemini CLI, ...) |
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
suggestions are welcome here; proposed code changes are treated as proposals, incorporated through
that development process, and come back in a reviewed release.

## License

MIT - see [LICENSE](LICENSE). Copyright (c) 2026 Nicholas Atkins.
