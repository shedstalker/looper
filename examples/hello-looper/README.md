# Example: hello-looper

A real, unedited Looper run from 2026-09-30, re-recorded with the release that binds the final
report by hash (the first recording, from 2026-09-27, is in the git history). Driver lock files
and raw transcripts were removed; in the two driver logs the user's home folder was replaced with
`C:\Users\<user>\`, and the repository stores the review and logs with LF line endings (the
handoff and report already had them, so their hashes are unchanged). Nothing else was edited.

- **Task:** in a tiny git repo, change `value.txt` from `1` to `2`, change nothing else, commit locally.
- **Worker:** a fresh Claude Code session (`claude -p`, model `claude-opus-5-5`), given only the
  three-line request below. It read `prompts/worker.md`, created the task folder, wrote PLAN
  and TASK, made the commit, wrote FINAL_REPORT and published handoff 001 asking for the final
  review. `publish` added the report's SHA-256 to the handoff (its last line).
- **Reviewer:** Codex (`codex exec`, runtime-reported `gpt-6.1-sol`, high) started via
  `drivers/codex/run.ps1`. It independently checked the commit, its tree, parent and blobs, and
  that the report still matched the hash in the handoff, then published PASS (about 3 minutes).
- **Worker driver:** `drivers/claude-code/run.ps1 -Role worker` saw `NEXT: done` and exited.
  No human relayed anything after the first prompt.

```text
Use Looper for this task. Looper is at C:\PROJECTS\Looper - start by reading its prompts\worker.md.
Task: in the git repo C:\Projects\Looper-Test\hello-v032, value.txt contains 1. Change it to 2 and
change nothing else. Commit the change locally (no push). [...]
```

Read it in the order a cold-starting agent would: [`.looper/CONTEXT.md`](.looper/CONTEXT.md),
[`PLAN.md`](.looper/PLAN.md), [`TASK.md`](.looper/TASK.md),
[`EXCHANGE/HANDOFF.md`](.looper/EXCHANGE/HANDOFF.md), [`EXCHANGE/REVIEW.md`](.looper/EXCHANGE/REVIEW.md),
[`FINAL_REPORT.md`](.looper/FINAL_REPORT.md), [`WATCHERS/*.log`](.looper/WATCHERS/).

`status` on this folder says `NEXT: done`, also after a git clone, which does not keep file
times. Paths inside point at the original test machine.

One honest imperfection the run left: the one-shot worker also started a reviewer driver in the
background, which ended with the worker's session after "attempt start" (the first two lines of
`reviewer.log`). The handoff simply stayed due, and the next reviewer driver answered it. The
worker prompt now says not to start drivers from a one-shot run.
