# PLAN

## Outcome
In `C:\Projects\Looper-Test\hello-v032`, `value.txt` contains `2` instead of `1`, committed
locally as one new commit on `master` on top of `e44c5fb`. Nothing else changes.

## Context
Repo `C:\Projects\Looper-Test\hello-v032`, branch `master`, HEAD `e44c5fb value 1`, clean tree.
`value.txt` is the only tracked file; its bytes are `31 0A` ("1\n").

## Boundaries
- Allowed: edit `value.txt` (1 -> 2, keeping the trailing LF), set the repo-local identity
  `user.name "Looper Test"`, `user.email test@example.invalid` (user asked), and commit locally.
- Not allowed: any other tracked change, history rewrite, other files or repos.
- Reserved for the human: push, merge into `main`, anything external.

## Proof
- `git show --stat HEAD`: exactly one file, `value.txt`, 1 insertion / 1 deletion.
- `value.txt` bytes are `32 0A`; parent of HEAD is `e44c5fb`; author/committer is Looper Test.
- `git status` clean for tracked files (the `.looper/` folder is excluded via `.git/info/exclude`).

## Escalation
Stop and ask if the repo is not in the state described in Context.

Worker freedom: inside this boundary the worker chooses the approach, order and tests.
