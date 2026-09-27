# PLAN

## Outcome

In the git repo `C:\Projects\Looper-Test\manual`, `greeting.txt` reads `hello looper`, and that
change is committed locally on branch `main`. Nothing is pushed.

## Context

- Repo: `C:\Projects\Looper-Test\manual`, branch `main`, one prior commit `3e6cc0e init`.
- Starting state: `greeting.txt` contained `hello world` followed by a trailing newline.
- Looper home `C:\Projects\Looper-Test\looper-noscripts` has **no helper scripts and no drivers**;
  the task folder and all publishing are done by hand per `docs/contract.md`.

## Boundaries

- Allowed: edit `greeting.txt`; commit locally; create and maintain `.looper/`.
- Not allowed: any other source change; rewriting history; touching other repos.
- Reserved for the human: `git push` (explicitly excluded by the task), remotes, branch changes,
  installing anything, any external write.

## Proof

- `greeting.txt` at the committed tree reads exactly `hello looper` (single line, trailing newline
  kept as in the original file).
- A new commit exists on `main` whose parent is `3e6cc0e`, touching only `greeting.txt`.
- `git status` shows no uncommitted change to tracked files; `.looper/` stays untracked.
- Negative case: no remote-affecting operation ran - the repo has no remote and no push occurred.

## Escalation

Stop and ask the human if the outcome would require a push, a remote, or a change to any file
other than `greeting.txt`. Isolated blockers are parked in `TASK.md` and work continues.

Worker freedom: inside this boundary the worker chooses the approach, order and tests.
