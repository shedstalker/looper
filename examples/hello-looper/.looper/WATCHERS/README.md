# WATCHERS

Wake-up plumbing only. Nothing here decides whether work is correct, edits source or grants
authority. The truth is always recomputed from the files by `status`.

- Worker wake-up: a Looper worker driver starts a fresh Claude Code session when a review is
  published. This worker session is headless and stops after publishing a handoff.
- Reviewer wake-up: Codex, started once by the human with
  `pwsh -NoProfile -File C:\PROJECTS\Looper\drivers\codex\run.ps1 -Loop C:\Projects\Looper-Test\hello\.looper`
  (default `-Role reviewer`).

Runtime files a driver may leave here: `<role>.lock` (held while a driver runs; released by the
OS if it dies), `<role>.log` (one line per attempt), `<role>-last.txt` (last child output).
