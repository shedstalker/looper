# TASK

## Work
1. [DONE] `value.txt` 1 -> 2, committed locally as `641e845e250f695bdfda6afe50fa1f6a6927737d`
   (tree `ced4cc706e4e6b0aa786ebb355ac9deb21cd8cfa`, parent `e44c5fb`), author/committer
   `Looper Test <test@example.invalid>`. Not pushed.
2. [IN REVIEW] Final handoff 001: commit + FINAL_REPORT.

## Notes
- Repo-local identity set with `git config user.name/user.email` (was unset; user asked for it).
- `core.autocrlf=true`: the working file is written as `32 0A`; the committed blob is `2\n`
  (`git cat-file -s HEAD:value.txt` = 2, same as the parent's `1\n`). Git's LF->CRLF warning is
  about future checkouts only.
- `.looper/` is excluded via `.git/info/exclude` (added by the helper's `new`).

## Parked / blocked
- none
