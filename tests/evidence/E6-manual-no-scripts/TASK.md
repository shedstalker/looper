# TASK

Shared live working memory for both roles.

## Work

1. [DONE] Create this task folder by hand from `looper-noscripts/template` (no helper scripts
   exist in this Looper copy), filling in CONTEXT/PLAN and recording the by-hand `NEXT:` rules
   and publish procedure in `CONTEXT.md`.
2. [DONE] Change `greeting.txt` from `hello world` to `hello looper`.
3. [DONE] Commit locally on `main`. Commit `2e2a3aadcebdb3e069dd75afb357ef07a835c529`,
   tree `dd55ea52e56c975901673839d91eece74df838f8`, parent `3e6cc0e`. No push.
4. [DONE] Write `FINAL_REPORT.md` (before publishing, so a PASS reaches `done`), then publish
   handoff **001**, id **`8b22543cb0fc`**, asking for the cumulative final review.
   `NEXT: reviewer` until a review naming that id is published.

## Notes

- Evidence gathered after the commit (all re-checkable):
  - `git show HEAD:greeting.txt` -> `hello looper` + LF, one line.
  - `git show --stat HEAD` -> `greeting.txt | 2 +-`, 1 file changed, 1 insertion, 1 deletion.
  - `git status --short` -> only `?? .looper/`; no tracked file is dirty.
  - `git remote -v` -> empty, so nothing could have been pushed.
- The commit message was first written with PowerShell here-string syntax (`@'...'@`) passed to a
  POSIX shell, which leaked the `@` delimiters into the message. Fixed with `git commit --amend
  -F -` and a heredoc before anything was published or shared; this is why the commit has an
  amend (the original bad-message commit was `daf0a8f`, now unreferenced).
- Line endings: the file is stored with LF in the tree, matching the original. Git warns
  `LF will be replaced by CRLF the next time Git touches it` because of the local core.autocrlf
  setting; that is a working-copy checkout detail, not a difference in the committed blob.

## Parked / blocked

- `.looper/` is **not** in `.git/info/exclude`: writing that file needs a permission the headless
  session was denied. Instead the commit named its path explicitly (`git commit ... -- greeting.txt`),
  so the task folder stayed untracked and out of the commit. It shows as `?? .looper/` in
  `git status`. A human who wants it hidden can add `.looper/` to `.git/info/exclude`.
- No wake-up plumbing is possible in this copy (no drivers, no `wait` helper). The human starts
  the reviewer once; see `WATCHERS/README.md`.
