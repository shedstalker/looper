# REVIEW

Verdict: REPAIR
Handoff: 001 eead2def7801

## What I checked

- Candidate identity: `git log -1` in `C:\Projects\Looper-Test\sum` gives commit
  `6e57ef360ab6348b4a1471e45cef63c8bc85bd75`, tree `f2b3387de9a1e2fb20d7aee01d0d067db3f4bb14`,
  branch `main`, working tree clean. This matches the handoff exactly, so I reviewed the
  committed state.
- Read `sum.ps1` and `numbers.txt` (4, 5, 6 with a single trailing newline; `numbers.txt`
  unmodified, as PLAN requires).
- PLAN proof case 1: `pwsh -NoProfile -File sum.ps1` in the project.
- PLAN proof case 2: copied `sum.ps1` plus a `numbers.txt` containing 10 and 20 into a scratch
  directory (the script reads `numbers.txt` next to itself via `$PSScriptRoot`) and ran it there.
  No project file was touched.

## Findings

1. **Both proof cases fail — off-by-one in the loop bound (blocking).**
   - `pwsh -NoProfile -File sum.ps1` prints `9`; PLAN requires `15`.
   - The 10/20 copy prints `10`; PLAN requires `30`.
   - Cause: `sum.ps1:3` loops `for ($i = 0; $i -lt $lines.Count - 1; $i++)`, which skips the
     last line. The `- 1` looks like an attempt to guard against the trailing blank line PLAN
     mentions, but `Get-Content` already drops the final newline, so there is no extra element
     to skip — the guard just discards a real number.
2. **Related: a one-line input prints `0`**, since `Count - 1` is then `0` and the loop body
   never runs. PLAN asks the script to work for any number of lines.
3. If a file genuinely ends in a blank line (two trailing newlines), `Get-Content` does yield an
   empty element, so the fix should skip blank/whitespace-only lines by content rather than by
   position.

Nothing else in PLAN is violated: only `sum.ps1` was added, `numbers.txt` is untouched, the work
is committed locally on `main`, and nothing was pushed.

## Next action

Worker: sum every line and filter blanks by content, e.g.

```powershell
$total = 0
foreach ($line in Get-Content (Join-Path $PSScriptRoot 'numbers.txt')) {
    if ($line.Trim()) { $total += [int]$line.Trim() }
}
Write-Output $total
```

Then re-run both PLAN proof cases (expect `15` and `30`), commit, and hand off again.
