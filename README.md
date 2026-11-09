# Looper

A tiny, model-agnostic worker/reviewer handoff built from ordinary files - informally, a boring
little mailbox for independent AI agents.

One agent does the work. A second, independent agent answers its requests: reviews, tests,
research, verification or other cross-model help. They talk through a handful of readable files in
a local folder, so you don't carry messages between them, and the job survives any session
crashing, compacting or being replaced.

The task folder holds CONTEXT (restart route), PLAN (boundaries and proof), TASK (shared working
memory), EXCHANGE/HANDOFF and REVIEW (current request/answer), HISTORY (numbered exchanges),
WATCHERS (runtime notes/logs) and FINAL_REPORT (closeout). Git remains source truth. Looper
grants no merge, deploy or external-write authority; a PASS applies to the exact candidate reviewed.

```text
worker --HANDOFF.md--> second agent --REVIEW.md--> worker --> ...
PASS on a handoff covering the current FINAL_REPORT = done
```

## Quick start

Both agents must run somewhere with local file access (a CLI agent, or a desktop app with local
file access); an ordinary browser chat cannot reach local files. The worker reads and writes your
project; the second agent only needs to read it and write its answer in the task folder. Keep
the task folder (by default `.looper/` in your project) on a local disk, not inside Google Drive,
OneDrive or Dropbox: their sync can delay or reorder the renames Looper relies on. A file that
lives there can still be attached to a handoff. The Windows examples use `C:\Projects\Looper`
and PowerShell; macOS/Linux is shown after the steps.

1. **Get Looper** - download a release, or clone it and update it like any git repository:

   ```text
   git clone https://github.com/shedstalker/looper C:\Projects\Looper
   ```

2. **Start the worker.** Open your worker agent (Claude Code, Codex, ...) in your project
   and tell it:

   ```text
   Use Looper for this task. Looper is at C:\Projects\Looper - read its prompts/worker.md.
   Task: <what you want done>.
   ```

   It creates `.looper/` in your project, fills PLAN and TASK, starts work, and gives you a
   one-line prompt for the second agent. (With the [Agent Skill](#as-an-agent-skill) installed,
   "Use Looper for this task: ..." is enough.) If your agent runs with an allow-list or in an
   auto mode, allow the Looper helper and drivers for every task folder it will use. For Claude
   Code, see [permissions](drivers/README.md#interactive-worker-and-permissions).

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

4. **Check progress** at any time. `status` only reads the files and prints whose move it is
   (`NEXT: worker`, `reviewer` or `done`); it never starts an agent:

   ```powershell
   pwsh -File C:\Projects\Looper\tools\looper.ps1 status <project>\.looper
   ```

   `NEXT: done` plus `FINAL_REPORT.md` means finished. (Windows without PowerShell 7:
   `powershell -ExecutionPolicy Bypass -File ...`.)

5. **Afterwards** the folder is the record. `clean` removes leftover runtime files (session
   ids, drafts), keeping lock files in place; keep the folder, or pack it and delete it. A later session on the same task simply
   continues the same folder.

**macOS / Linux.** Clone Looper anywhere and use the POSIX helper; only the optional drivers need
PowerShell 7. While cleaning, the sh helper holds driver locks with `flock(1)` or `pwsh`:

```sh
git clone https://github.com/shedstalker/looper ~/Looper
cd ~/my-project
# In your worker agent: "Use Looper for this task. Looper is at ~/Looper - read its prompts/worker.md. Task: ..."
sh ~/Looper/tools/looper.sh status .looper                 # whose move is it? (reads only)
pwsh -File ~/Looper/drivers/codex/run.ps1 -Loop .looper    # optional headless second agent
```

## Helpers and drivers

The helpers have the same commands; neither calls a model. Use `pwsh -File tools/looper.ps1`
(Windows PowerShell 5.1 also works) or `sh tools/looper.sh`, followed by:

| Command | Purpose |
|---|---|
| `new <folder> -Project <project>` | Create one task folder; an existing task is continued, never overwritten |
| `status <folder>` | Read state and print `NEXT: worker`, `reviewer` or `done` |
| `publish <folder> handoff\|review` | Publish the role's `.next.md` draft atomically and record HISTORY; stale answers are refused |
| `wait <folder> -For worker\|reviewer` | Wait for due work without model calls; it prints `LOOPER DUE <role>` and the reason, then read `EXCHANGE/REVIEW.md` (worker) or `EXCHANGE/HANDOFF.md` (reviewer) |
| `clean <folder>` | Remove disposable runtime files when no driver holds a lock; preserve the record |

For files outside Git, `publish ... handoff -Attach <file>` snapshots attachments into HISTORY
and lists sizes/hashes. The reviewer reads those snapshots. The full by-hand protocol, identity,
due rule and lifecycle are in [the contract](docs/contract.md).

Drivers for Claude Code and Codex CLI need
PowerShell 7. They wait on files, launch a role when due and optionally stream output with
`-Show`. Any file-capable agent can participate manually. The [driver guide](drivers/README.md)
covers runtime choice, tested models, flags, sessions, sign-in/cost, access and limits, including
Windows Codex builders that need a PowerShell zip and a finisher to commit their drafts.

## Evidence and limits

**78 acceptance checks**, without model calls; some are platform-specific and skip elsewhere.
Run `pwsh -File tests/acceptance.ps1` and add `-Helper sh` for the POSIX edition. Recorded runs
cover Windows (PowerShell 7/5.1, Git Bash) and Linux (pwsh/dash); CI also targets macOS.
[Testing](docs/testing.md) keeps the measured results and live-run evidence, including repairs,
crashes, restarts, session reuse, concurrent loops and operation with all scripts removed.

The longest live loops are under an hour; macOS live use and ChatGPT Skill upload remain
untried. Local models are useful second opinions but are not yet trusted as sole reviewers.
Looper supplies a mailbox; access boundaries come from the runtime or an enclosing container.

## Learn more

| | |
|---|---|
| [CONTEXT.md](CONTEXT.md) | Router for agents working on or with Looper |
| [docs/contract.md](docs/contract.md) | The Level 1 contract: files, identity, due rule, publishing, lifecycle |
| [prompts/](prompts/) | Worker and second-agent (reviewer) role instructions |
| [drivers/](drivers/README.md) | Picking a runtime (Claude Code, Codex); running each role visible, headless or manual; model and effort; sessions; local models |
| [integrations/host-snippet.md](integrations/host-snippet.md) | A paragraph to paste into another system's prompts so its agents ask for review at the right moments |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Reporting a problem, proposing a change, running the checks |
| [examples/hello-looper](examples/hello-looper/) | A complete real run |
| [docs/testing.md](docs/testing.md) | Evidence, measured platforms and limits |
| [docs/history.md](docs/history.md) | Origins, ICM / agent-as-file lineage, name and lessons |
| [CHANGELOG.md](CHANGELOG.md) | Release contents; only Level 1 is implemented |

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

The skill is generated from canonical repository files. [Packaging and validation](integrations/skill/README.md).

## Issues and changes

`shedstalker/looper` is the public release and product repository. Development and release
qualification happen separately, in the maintainers' development repository. Issues and
suggestions are welcome; proposed code changes are treated as proposals, incorporated through
that development process, and come back in a reviewed release. Open an issue at
[github.com/shedstalker/looper/issues](https://github.com/shedstalker/looper/issues); how to report a
problem so it can actually be fixed: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT - see [LICENSE](LICENSE). Copyright (c) 2026 Nicholas Atkins.
