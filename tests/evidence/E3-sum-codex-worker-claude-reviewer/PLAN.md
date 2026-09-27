# PLAN

## Outcome
`sum.ps1` in `C:\Projects\Looper-Test\sum` prints the sum of the integers in `numbers.txt`
(one per line), as a single number followed by a newline. Committed locally on `main`.

## Context
`numbers.txt` currently holds 4, 5, 6 (sum 15). The script must work for any number of lines,
including a trailing blank line.

## Boundaries
- Allowed: create/edit `sum.ps1`; local git add/commit; run the script.
- Not allowed: changing `numbers.txt`; other files.
- Reserved for the human: push.

## Proof
Running `pwsh -NoProfile -File sum.ps1` prints `15`. A second input (e.g. a temp copy with
10 and 20) gives `30`.

## Escalation
Ask the human only if a reserved action is needed.
