# WATCHERS

Wake-up plumbing only. Nothing here decides whether work is correct, edits source or grants
authority. The truth is always recomputed from the files by `status`.

Record what is actually running for this task - the exact command where there is one - so a
restarted agent or a human can see it and start it again the same way:

- Worker: (e.g. an interactive session waiting on `looper wait --for worker`; or manual)
- Reviewer: (e.g. the exact driver command line, with provider, model and effort; a scheduled
  one-line prompt; or manual)

Runtime files a driver may leave here: `<role>.lock` (held while a driver runs; released by the
OS if it dies), `<role>.log` (one line per attempt), `<role>-last.txt` (last child output).
