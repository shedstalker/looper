# Looper task: hello-value

This folder is a **Looper L1** task: one WORKER does the work, one independent second agent
(the REVIEWER) answers the worker's requests. They talk only through the files here. Agent
sessions are disposable; these files are the durable state. If you have just started or
restarted, this file is the right place to begin.

- Task folder: `C:\Projects\Looper-Test\hello\.looper`
- Project / source: `C:\Projects\Looper-Test\hello`
- Looper home: `C:\PROJECTS\Looper`
- Helper: `pwsh -NoProfile -File "C:\PROJECTS\Looper\tools\looper.ps1" <command> "C:\Projects\Looper-Test\hello\.looper"`
- Created: 2026-09-27 13:17

## Files

| File | Owner | Purpose |
|---|---|---|
| `PLAN.md` | worker (set at start) | Task boundary: outcome, context, boundaries, proof, escalation. |
| `TASK.md` | shared | Live working memory. Both roles may add notes. Read it first after a restart. |
| `EXCHANGE/HANDOFF.md` | worker | The worker's current request: what to review, check, research, compare or fetch. |
| `EXCHANGE/REVIEW.md` | reviewer | The answer to that exact handoff: `Verdict: PASS / REPAIR / BLOCKED` plus findings. |
| `HISTORY/` | helper | Every published handoff and review, numbered. Evidence, not active state. |
| `WATCHERS/` | each role its own | Wake-up plumbing notes, locks and logs. Never decides anything. |
| `FINAL_REPORT.md` | worker | Closeout, written from these files at the end. |

## Whose move is it?

Run `status`. It prints one `NEXT:` line: `worker`, `reviewer` or `done`.
A handoff stays due until a review naming that handoff's id is published.

## Route

- **WORKER** - read `C:\PROJECTS\Looper/prompts/worker.md`, then `PLAN.md`, `TASK.md`, the current exchange.
- **REVIEWER** - read `C:\PROJECTS\Looper/prompts/reviewer.md`, then `PLAN.md`, `TASK.md`, `EXCHANGE/HANDOFF.md`.
- **Human** - `status`, then `TASK.md`, then `HISTORY/` or `FINAL_REPORT.md`.

## Essentials (if the Looper home is unavailable)

1. Publish by writing `EXCHANGE/HANDOFF.next.md` or `EXCHANGE/REVIEW.next.md`, then run `publish ... handoff|review`.
2. A review must contain `Verdict: PASS|REPAIR|BLOCKED` and `Handoff: <number> <id>` copied from `status`.
3. Only publish a review at the end of a completed review. A crashed attempt publishes nothing, so the handoff stays due.
4. The reviewer does not edit the worker's source. The worker does not write REVIEW.md.
5. Soft format, hard identity: tolerate wording and layout; be strict about *what exactly* is being answered.
6. PLAN owns the boundary, TASK records the work, Git owns source truth, REVIEW owns the verdict.
7. Looper grants no authority: no merge, deploy, install or external write unless PLAN allows it.
