# Example: hello-looper

A real, unedited Looper run from 2026-09-27 (only driver lock and raw transcript files removed).

- **Task:** in a tiny git repo, change `value.txt` from `1` to `2`, change nothing else, commit locally.
- **Worker:** a fresh Claude Code session (`claude -p`, model claude-opus-5), given only the
  three-line request below. It read `prompts/worker.md`, created the task folder, wrote PLAN
  and TASK, made the commit, wrote FINAL_REPORT and published handoff 001 asking for the final
  review.
- **Reviewer:** Codex (`codex exec`, model gpt-6-sol) started once via `drivers/codex/run.ps1`.
  It independently read the git blobs, tree and parent, and published PASS.
- **Worker driver:** `drivers/claude-code/run.ps1 -Role worker` saw `NEXT: done` and exited.
  No human relayed anything after the first prompt.

```text
Use Looper for this task. Looper is at C:\PROJECTS\Looper - start by reading its prompts\worker.md.
Task: in the git repo C:\Projects\Looper-Test\hello, value.txt contains 1. Change it to 2 and
change nothing else. Commit the change locally (no push). [...]
```

Read it in the order a cold-starting agent would: [`.looper/CONTEXT.md`](.looper/CONTEXT.md),
[`PLAN.md`](.looper/PLAN.md), [`TASK.md`](.looper/TASK.md),
[`EXCHANGE/HANDOFF.md`](.looper/EXCHANGE/HANDOFF.md), [`EXCHANGE/REVIEW.md`](.looper/EXCHANGE/REVIEW.md),
[`FINAL_REPORT.md`](.looper/FINAL_REPORT.md), [`WATCHERS/*.log`](.looper/WATCHERS/).

Paths inside point at the original test machine. Note one honest imperfection the run left:
TASK.md item 4 still says the final report is TODO although it was written - TASK is working
memory, not a contract, and the reviewer judged the actual outcome.
