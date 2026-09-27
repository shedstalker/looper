# PLAN

## Outcome
In the git repo `C:\Projects\Looper-Test\hello`, `value.txt` contains `2` instead of `1`, and
that change is committed locally on `main`. Nothing else in the repo is changed.

## Context
- Repo: `C:\Projects\Looper-Test\hello`, branch `main`, starting commit `de659ea` ("Initial state").
- Files: `README.md`, `value.txt` (content `1`).
- The task folder `.looper` is excluded from the repo via `.git/info/exclude`, so it never
  appears in the commit.

## Boundaries
- Allowed: edit `value.txt`, run git commands that only touch the local repo (add, commit,
  diff, log, status), write inside `.looper`.
- Not allowed: any other source change, README edits, branch creation, history rewriting,
  amending or reverting `de659ea`.
- Reserved for the human: `git push` and any other remote or external write.

## Proof
- `git show <commit>:value.txt` is `2`.
- `git diff de659ea..<commit> --stat` shows exactly one file changed, `value.txt`, 1 insertion
  and 1 deletion.
- `git status --porcelain` in the repo is clean (the `.looper` folder is excluded, not committed).
- Negative case: the commit must not contain `README.md`, `.looper` or any other path.

## Escalation
Stop and ask the human if the repo turns out to be dirty in ways this task did not cause, or if
the outcome cannot be reached without a reserved action (e.g. a push).
