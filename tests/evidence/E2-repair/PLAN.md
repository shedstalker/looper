# PLAN

## Outcome
In the git repo `C:\Projects\Looper-Test\repair` (branch `main`), `value.txt` contains `2`, and
`CHANGELOG.md` has one new bullet at the end recording the change: `- value: 1 -> 2`.
Both changes are committed locally. Nothing else changes.

## Context
Starting commit `41f46a6` ("Initial state"): `value.txt` = `1`; `CHANGELOG.md` has one bullet.

## Boundaries
- Allowed: edit `value.txt` and `CHANGELOG.md`; local git add/commit/diff/log/status; write in `.looper`.
- Not allowed: other files, history rewriting, branches.
- Reserved for the human: push or any remote write.

## Proof
Reviewer checks the committed tree: `value.txt` is `2`; `CHANGELOG.md` gained exactly the one bullet;
no other path changed.

## Escalation
Ask the human only if the outcome needs a reserved action.
