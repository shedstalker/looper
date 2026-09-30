#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deterministic Looper L1 acceptance checks (no model calls). Runs in a disposable folder.

.EXAMPLE
  pwsh -File tests/acceptance.ps1                      # tests tools/looper.ps1
  pwsh -File tests/acceptance.ps1 -Helper sh           # tests tools/looper.sh (needs sh)
  powershell -NoProfile -ExecutionPolicy Bypass -File tests/acceptance.ps1
#>
param(
    [ValidateSet('ps1', 'sh')][string]$Helper = 'ps1',
    [string]$Scratch = (Join-Path ([IO.Path]::GetTempPath()) ('looper-acceptance-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$helperKind = $Helper
$helperPath = Join-Path $repo "tools/looper.$Helper"
$ps1Helper = Join-Path $repo 'tools/looper.ps1'   # drivers are PowerShell
$agentLoop = Join-Path $repo 'drivers/generic/agent-loop.ps1'
$opencodeRun = Join-Path $repo 'drivers/opencode/run.ps1'
$shell = (Get-Process -Id $PID).Path
$script:failed = 0

function Check([string]$Name, [scriptblock]$Test) {
    try {
        $ok = & $Test
        if ($ok -is [string] -and $ok -eq 'skip') { Write-Output "SKIP  $Name"; return }
        if ($ok -ne $true) { throw "returned $ok" }
        Write-Output "PASS  $Name"
    } catch {
        $script:failed++
        Write-Output "FAIL  $Name - $($_.Exception.Message)"
    }
}

function Looper {
    # Run the helper in a child shell so its exit code and stderr are captured like a user sees them.
    $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 would turn child stderr into an exception
    $out = if ($helperKind -eq 'sh') { & sh $helperPath @args 2>&1 } else { & $shell -NoProfile -ExecutionPolicy Bypass -File $helperPath @args 2>&1 }
    $script:code = $LASTEXITCODE
    ($out | ForEach-Object { "$_" }) -join "`n"
}

function Next { [regex]::Match((Looper status $loop), '(?m)^NEXT: (\w+)').Groups[1].Value }
function Id { [regex]::Match((Looper status $loop), '(?m)^handoff: (\d+ [0-9a-f]{12})').Groups[1].Value }
function Draft([string]$Kind, [string]$Text) { [IO.File]::WriteAllText((Join-Path $loop "EXCHANGE/$Kind.next.md"), $Text) }
function Sha([string]$Path) {
    # Plain .NET, not Get-FileHash: some agent sandboxes cannot load that cmdlet's module.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
$project = Join-Path $Scratch 'project'
New-Item -ItemType Directory -Path $project | Out-Null
Set-Content -LiteralPath (Join-Path $project 'value.txt') -Value '1'
$gitOk = $true
try {
    $ErrorActionPreference = 'Continue'
    & git -C $project init -q 2>$null
    & git -C $project -c user.name=t -c user.email=t@example.invalid add . 2>$null
    & git -C $project -c user.name=t -c user.email=t@example.invalid commit -qm init 2>$null
    if ($LASTEXITCODE -ne 0) { $gitOk = $false }
} catch { $gitOk = $false } finally { $ErrorActionPreference = 'Stop' }
$loop = Join-Path $project '.looper'
Write-Output "Scratch: $Scratch  (PowerShell $($PSVersionTable.PSVersion), helper tools/looper.$Helper)"

Check 'bootstrap: new creates the task folder' {
    $out = Looper new $loop -Task demo -Project $project
    ($code -eq 0) -and (Test-Path (Join-Path $loop 'EXCHANGE/HANDOFF.md')) -and ($out -match 'You are the REVIEWER for the Looper task at') -and
    ((Get-Content -Raw (Join-Path $loop 'CONTEXT.md')) -notmatch '\{\{')
}
Check 'bootstrap: task folder kept out of commits (.git/info/exclude)' {
    if (-not $gitOk) { return 'skip' }   # git not installed
    (Get-Content -Raw (Join-Path $project '.git/info/exclude')) -match '/\.looper/'
}
Check 'bootstrap: in a git worktree the folder is excluded where git reads it (the shared info/exclude)' {
    if (-not $gitOk) { return 'skip' }
    $wt = Join-Path $Scratch 'worktree'
    $ErrorActionPreference = 'Continue'; & git -C $project worktree add -q $wt 2>$null; $ErrorActionPreference = 'Stop'
    if (-not (Test-Path (Join-Path $wt 'value.txt'))) { return $false }
    # Its own folder name: the main checkout's shared exclude already covers /.looper/.
    $null = Looper new (Join-Path $wt 'wt-task/.looper') -Project $wt; $newCode = $code
    $ErrorActionPreference = 'Continue'; $st = & git -C $wt status --porcelain 2>$null; $ErrorActionPreference = 'Stop'
    ($newCode -eq 0) -and (@($st | Where-Object { $_ -match 'wt-task' }).Count -eq 0)
}
Check 'bootstrap: new never overwrites an existing folder' { $null = Looper new $loop; $code -ne 0 }
Check 'fresh folder: NEXT is worker' { (Next) -eq 'worker' }
Check 'template text cannot be published' {
    Copy-Item (Join-Path $loop 'EXCHANGE/HANDOFF.md') (Join-Path $loop 'EXCHANGE/HANDOFF.next.md')
    $null = Looper publish $loop handoff
    $ok = $code -ne 0; Remove-Item (Join-Path $loop 'EXCHANGE/HANDOFF.next.md'); $ok
}
Check 'worker handoff: publish makes the reviewer due and logs HISTORY/001' {
    Draft HANDOFF "Request: review`nCandidate: value.txt = 2`n"
    $null = Looper publish $loop handoff
    ($code -eq 0) -and ((Next) -eq 'reviewer') -and (Test-Path (Join-Path $loop 'HISTORY/001_HANDOFF.md')) -and
    -not (Test-Path (Join-Path $loop 'EXCHANGE/HANDOFF.next.md'))
}
Check 'unchanged handoff stays quiet (no new history entry)' {
    Draft HANDOFF "Request: review`nCandidate: value.txt = 2`n"
    $out = Looper publish $loop handoff
    ($out -match 'unchanged') -and (@(Get-ChildItem (Join-Path $loop 'HISTORY')).Count -eq 1)
}
Check 'review without a handoff id is refused' { Draft REVIEW "Verdict: PASS`n"; $null = Looper publish $loop review; $code -ne 0 }
Check 'review that only mentions a handoff as "previous" does not bind' {
    Draft REVIEW "Verdict: PASS`nPrevious handoff: $(Id)`n"; $null = Looper publish $loop review; $code -ne 0
}
Check 'reviewer REPAIR (soft format: heading + bold + lowercase) binds and hands back to worker' {
    Draft REVIEW "# Review`n`n## Verdict`n`n**repair**`n`n- **Reviewed handoff**: ``$(Id)```n- value.txt should be 2, not 3`n"
    $out = Looper publish $loop review
    ($code -eq 0) -and ($out -match 'NEXT: worker') -and ((Next) -eq 'worker') -and ((Looper status $loop) -match 'review:  REPAIR for handoff 001') -and
    (Test-Path (Join-Path $loop 'HISTORY/001_REVIEW.md'))
}
Check 'repair: new handoff makes the reviewer due again' {
    Draft HANDOFF "Request: review`nCandidate: value.txt = 2 (repaired)`n"
    $null = Looper publish $loop handoff
    ($code -eq 0) -and ((Next) -eq 'reviewer') -and ((Id) -like '002 *')
}
Check 'replay: re-publishing an earlier handoff text is refused (its old answer must not settle it)' {
    # Found by the dogfood review: A -> PASS, B, then A again inherited the old PASS.
    Draft HANDOFF "Request: review`nCandidate: value.txt = 2`n"
    $null = Looper publish $loop handoff
    $refused = $code -ne 0
    Remove-Item (Join-Path $loop 'EXCHANGE/HANDOFF.next.md') -ErrorAction SilentlyContinue
    $refused -and ((Id) -like '002 *') -and ((Next) -eq 'reviewer')
}
$stale = $null
Check 'stale review (names handoff 001) is refused and changes nothing' {
    $script:stale = Sha (Join-Path $loop 'EXCHANGE/REVIEW.md')
    $old = (Get-Content -Raw (Join-Path $loop 'HISTORY/001_HANDOFF.md'))
    $oldId = (Sha (Join-Path $loop 'HISTORY/001_HANDOFF.md')).Substring(0, 12)
    Draft REVIEW "Verdict: PASS`nHandoff: 001 $oldId`n"
    $null = Looper publish $loop review
    ($code -eq 4) -and ((Sha (Join-Path $loop 'EXCHANGE/REVIEW.md')) -eq $script:stale) -and ((Next) -eq 'reviewer') -and $old
}
Check 'interrupted reviewer (draft + half-written temp, no publish): handoff stays due, previous review intact' {
    Draft REVIEW "Verdict: PASS`nHandoff: $(Id)`nhalf-finished..."
    [IO.File]::WriteAllText((Join-Path $loop 'EXCHANGE/.REVIEW.md.deadbeef.tmp'), 'Verdict: PA')
    ((Next) -eq 'reviewer') -and ((Sha (Join-Path $loop 'EXCHANGE/REVIEW.md')) -eq $script:stale)
}
Check 'failed replace publishes nothing: no new HISTORY entry, REVIEW untouched, draft kept' {
    # Found in dogfooding: a sandbox allowed creating files but not replacing REVIEW.md.
    $review = Join-Path $loop 'EXCHANGE/REVIEW.md'
    $saved = [IO.File]::ReadAllBytes($review)
    $countBefore = @(Get-ChildItem (Join-Path $loop 'HISTORY')).Count
    Remove-Item $review; New-Item -ItemType Directory -Path $review | Out-Null   # unreplaceable target
    try {
        Draft REVIEW "Verdict: PASS`nHandoff: $(Id)`n"
        $null = Looper publish $loop review
        ($code -ne 0) -and (@(Get-ChildItem (Join-Path $loop 'HISTORY')).Count -eq $countBefore) -and
        (Test-Path (Join-Path $loop 'EXCHANGE/REVIEW.next.md'))
    } finally {
        Remove-Item $review -Recurse -Force; [IO.File]::WriteAllBytes($review, $saved)
        Remove-Item (Join-Path $loop 'EXCHANGE/REVIEW.next.md') -ErrorAction SilentlyContinue
    }
}
Check 'restart: a fresh wait notices due work already present' {
    $out = Looper wait $loop -For reviewer -TimeoutMinutes 0.05
    ($code -eq 0) -and ($out -match 'DUE reviewer')
}
Check 'quiet: wait for the worker times out when nothing is due (exit 3)' {
    $out = Looper wait $loop -For worker -TimeoutMinutes 0.05 -PollSeconds 1
    ($code -eq 3) -and ($out -match 'TIMEOUT')
}
Check 'wake-up: waiting worker wakes within seconds of a published review' {
    $id = Id
    $job = Start-Job -ArgumentList $shell, $helperPath, $loop, $id -ScriptBlock {
        param($shell, $helperPath, $loop, $id)
        Start-Sleep -Seconds 3
        [IO.File]::WriteAllText((Join-Path $loop 'EXCHANGE/REVIEW.next.md'), "Verdict: PASS`nHandoff: $id`n")
        if ($helperPath.EndsWith('.sh')) { & sh $helperPath publish $loop review | Out-Null } else { & $shell -NoProfile -ExecutionPolicy Bypass -File $helperPath publish $loop review | Out-Null }
    }
    $t = [Diagnostics.Stopwatch]::StartNew()
    $out = Looper wait $loop -For worker -TimeoutMinutes 1 -PollSeconds $(if ($helperKind -eq 'sh') { 2 } else { 60 })
    $t.Stop(); Receive-Job $job -Wait | Out-Null; Remove-Job $job
    ($code -eq 0) -and ($out -match 'DUE worker') -and ($t.Elapsed.TotalSeconds -lt 45)
}
Check 'HISTORY is a readable ordered log' {
    $names = @(Get-ChildItem (Join-Path $loop 'HISTORY') | ForEach-Object Name)
    ($names -join ',') -eq '001_HANDOFF.md,001_REVIEW.md,002_HANDOFF.md,002_REVIEW.md'
}
Check 'not done early: FINAL_REPORT written after the last PASS still needs a final review' {
    # Regression: a live run briefly read "done" between writing the report and the final handoff.
    [IO.File]::WriteAllText((Join-Path $loop 'FINAL_REPORT.md'), "# FINAL REPORT`nvalue.txt is 2.`n")
    (Next) -eq 'worker'
}
Check 'done: final handoff (after the report) + PASS -> NEXT done, wait exits 2' {
    Start-Sleep -Milliseconds 50
    Draft HANDOFF "Request: final review`nCandidate: value.txt = 2, plus FINAL_REPORT.md`n"
    $null = Looper publish $loop handoff
    Draft REVIEW "Verdict: PASS`nHandoff: $(Id)`n"
    $published = Looper publish $loop review   # the publish message itself reports done
    $null = Looper wait $loop -For reviewer -TimeoutMinutes 0.05
    $waitCode = $code
    ((Next) -eq 'done') -and ($waitCode -eq 2) -and ($published -match 'NEXT: done')
}

# A non-review request: the answer needs only the handoff identity, no verdict.
$loop3 = Join-Path $Scratch 'research/.looper'
$null = Looper new $loop3 -Project (Join-Path $Scratch 'research')
Check 'research request: a plain answer without a verdict settles the handoff' {
    [IO.File]::WriteAllText((Join-Path $loop3 'EXCHANGE/HANDOFF.next.md'), "Request: research`nWhich port does the dev server use?`n")
    $null = Looper publish $loop3 handoff
    $id = [regex]::Match((Looper status $loop3), '(?m)^handoff: (\d+ [0-9a-f]{12})').Groups[1].Value
    [IO.File]::WriteAllText((Join-Path $loop3 'EXCHANGE/REVIEW.next.md'), "Handoff: $id`nIt uses port 5173 (vite.config.ts line 4).`n")
    $null = Looper publish $loop3 review
    $s = Looper status $loop3
    ($code -eq 0) -and ($s -match 'review:  ANSWER for handoff 001') -and ($s -match '(?m)^NEXT: worker')
}

# Attachments: files outside Git, snapshotted into HISTORY and listed in the handoff.
$loop7 = Join-Path $Scratch 'attach/.looper'
$null = Looper new $loop7 -Project (Join-Path $Scratch 'attach')
$docs = Join-Path $Scratch 'docs'; New-Item -ItemType Directory -Force $docs | Out-Null
$brief = Join-Path $docs 'brief one.md'; $export = Join-Path $docs 'export.bin'
[IO.File]::WriteAllText($brief, "brief v1`n"); [IO.File]::WriteAllBytes($export, [byte[]](0, 1, 2, 255))
function Draft7 { [IO.File]::WriteAllText((Join-Path $loop7 'EXCHANGE/HANDOFF.next.md'), "Request: review`nCandidate: the attached brief`n") }
function Hist7 { @(Get-ChildItem (Join-Path $loop7 'HISTORY') -Name | Sort-Object) -join ',' }
Check 'attach: files are snapshotted into HISTORY/001_attachments and listed with size and SHA-256' {
    Draft7
    $null = Looper publish $loop7 handoff -Attach "$brief,$export"
    $text = [IO.File]::ReadAllText((Join-Path $loop7 'EXCHANGE/HANDOFF.md'))
    $snap = Join-Path $loop7 'HISTORY/001_attachments'
    ($code -eq 0) -and ((Sha "$snap/brief one.md") -eq (Sha $brief)) -and ((Sha "$snap/export.bin") -eq (Sha $export)) -and
    $text.Contains("- ``brief one.md``: 9 bytes, sha256 $(Sha $brief)") -and $text.Contains("- ``export.bin``: 4 bytes, sha256 $(Sha $export)")
}
Check 'attach: same text and files stay quiet; an edited file makes a new handoff with its own snapshot' {
    Draft7; $quiet = Looper publish $loop7 handoff -Attach "$brief,$export"; $quietCode = $code
    [IO.File]::WriteAllText($brief, "brief v2`n")
    Draft7; $null = Looper publish $loop7 handoff -Attach "$brief,$export"
    ($quietCode -eq 0) -and ($quiet -match 'unchanged') -and ($code -eq 0) -and
    ((Hist7) -eq '001_attachments,001_HANDOFF.md,002_attachments,002_HANDOFF.md') -and
    ((Sha (Join-Path $loop7 'HISTORY/002_attachments/brief one.md')) -eq (Sha $brief))
}
Check 'attach: a missing file or a failed publish leaves no handoff and no snapshot' {
    $before = Hist7
    Draft7; $null = Looper publish $loop7 handoff -Attach (Join-Path $docs 'missing.md'); $missingCode = $code
    $handoff = Join-Path $loop7 'EXCHANGE/HANDOFF.md'; $saved = [IO.File]::ReadAllBytes($handoff)
    Remove-Item $handoff; New-Item -ItemType Directory -Path $handoff | Out-Null   # unreplaceable target
    try {
        [IO.File]::WriteAllText($brief, "brief v3`n")
        Draft7; $null = Looper publish $loop7 handoff -Attach $brief
        ($missingCode -ne 0) -and ($code -ne 0) -and ((Hist7) -eq $before)
    } finally {
        Remove-Item $handoff -Recurse -Force; [IO.File]::WriteAllBytes($handoff, $saved)
        Remove-Item (Join-Path $loop7 'EXCHANGE/HANDOFF.next.md') -ErrorAction SilentlyContinue
    }
}
Check 'attach: a failed HISTORY write leaves no snapshot, keeps the draft and current handoff; the retry works' {
    $obstacle = Join-Path $loop7 'HISTORY/003_HANDOFF.md'
    $current = Sha (Join-Path $loop7 'EXCHANGE/HANDOFF.md')
    New-Item -ItemType Directory -Path $obstacle | Out-Null   # the history copy cannot be written
    [IO.File]::WriteAllText($brief, "brief v4`n")
    Draft7; $null = Looper publish $loop7 handoff -Attach $brief; $failCode = $code
    $clean = -not (Test-Path (Join-Path $loop7 'HISTORY/003_attachments')) -and (Test-Path (Join-Path $loop7 'EXCHANGE/HANDOFF.next.md')) -and
        ((Sha (Join-Path $loop7 'EXCHANGE/HANDOFF.md')) -eq $current)
    Remove-Item $obstacle
    $null = Looper publish $loop7 handoff -Attach $brief   # the kept draft, once the obstacle is gone
    ($failCode -ne 0) -and $clean -and ($code -eq 0) -and
    ((Sha (Join-Path $loop7 'HISTORY/003_attachments/brief one.md')) -eq (Sha $brief))
}
Check 'attach: restoring the latest handoff reuses its snapshot; the next changed file makes the next handoff' {
    Remove-Item (Join-Path $loop7 'EXCHANGE/HANDOFF.md')   # the current copy was lost
    Draft7; $restored = Looper publish $loop7 handoff -Attach $brief; $restoreCode = $code
    $afterRestore = Hist7
    $v4 = Sha $brief
    [IO.File]::WriteAllText($brief, "brief v5`n")
    Draft7; $null = Looper publish $loop7 handoff -Attach $brief
    ($restoreCode -eq 0) -and ($restored -match 'published handoff 003') -and ($afterRestore -notmatch '004') -and ($code -eq 0) -and
    ((Sha (Join-Path $loop7 'HISTORY/003_attachments/brief one.md')) -eq $v4) -and
    ((Sha (Join-Path $loop7 'HISTORY/004_attachments/brief one.md')) -eq (Sha $brief))
}
Check 'attach: restoring reuses only a byte-identical snapshot, whatever the file name (..evidence.bin)' {
    $loop8 = Join-Path $Scratch 'attach-dots/.looper'
    $null = Looper new $loop8 -Project (Join-Path $Scratch 'attach-dots')
    $odd = Join-Path $docs '..evidence.bin'; [IO.File]::WriteAllBytes($odd, [byte[]](1, 2, 3))
    $handoff = Join-Path $loop8 'EXCHANGE/HANDOFF.md'; $snap = Join-Path $loop8 'HISTORY/001_attachments/..evidence.bin'
    function Draft8 { [IO.File]::WriteAllText((Join-Path $loop8 'EXCHANGE/HANDOFF.next.md'), "Request: review`nCandidate: evidence`n") }
    Draft8; $null = Looper publish $loop8 handoff -Attach $odd; $firstCode = $code
    Remove-Item $handoff; Draft8; $null = Looper publish $loop8 handoff -Attach $odd; $intactCode = $code   # intact: restored
    Remove-Item $handoff; [IO.File]::WriteAllBytes($snap, [byte[]](9, 9, 9))                                 # tampered snapshot
    Draft8; $null = Looper publish $loop8 handoff -Attach $odd
    ($firstCode -eq 0) -and ($intactCode -eq 0) -and ($code -ne 0) -and -not (Test-Path $handoff) -and
    (Test-Path (Join-Path $loop8 'EXCHANGE/HANDOFF.next.md')) -and (([IO.File]::ReadAllBytes($snap) -join ',') -eq '9,9,9')
}

# Driver behaviour, with a fake agent instead of a model.
$loop2 = Join-Path $Scratch 'driver/.looper'
$null = Looper new $loop2 -Project (Join-Path $Scratch 'driver')
[IO.File]::WriteAllText((Join-Path $loop2 'EXCHANGE/HANDOFF.next.md'), "Request: review`nCandidate: nothing`n")
$null = Looper publish $loop2 handoff
Check 'driver: failed attempts publish nothing, work stays due, gives up after MaxFailures (exit 5)' {
    & $agentLoop -Loop $loop2 -Role reviewer -Exe $shell `
        -Arguments '-NoProfile', '-Command', 'exit 7' -MaxFailures 2 -RetrySeconds 0 | Out-Null
    $log = Get-Content -Raw (Join-Path $loop2 'WATCHERS/reviewer.log')
    ($LASTEXITCODE -eq 5) -and ($log -match 'without publishing \(exit 7\).*\(2/2\)') -and
    ([regex]::Match((Looper status $loop2), '(?m)^NEXT: (\w+)').Groups[1].Value -eq 'reviewer')
}
Check 'driver: only one driver per role (lock held -> exit 4)' {
    $lock = [IO.File]::Open((Join-Path $loop2 'WATCHERS/reviewer.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        & $agentLoop -Loop $loop2 -Role reviewer -Exe $shell -Arguments '-Command', 'exit 0' | Out-Null
        $LASTEXITCODE -eq 4
    } finally { $lock.Dispose() }
}
Check 'driver: a fake reviewer that publishes is detected; the loop moves on' {
    $fake = Join-Path $Scratch 'fake-reviewer.ps1'
    Set-Content -LiteralPath $fake -Value @"
`$id = [regex]::Match(((& '$ps1Helper' status '$loop2') -join "``n"), '(?m)^handoff: (\d+ [0-9a-f]{12})').Groups[1].Value
[IO.File]::WriteAllText((Join-Path '$loop2' 'EXCHANGE/REVIEW.next.md'),"Verdict: PASS``nHandoff: `$id``n")
& '$ps1Helper' publish '$loop2' review
"@
    & $agentLoop -Loop $loop2 -Role reviewer -Exe $shell `
        -Arguments '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fake -Once | Out-Null
    ($LASTEXITCODE -eq 0) -and ((Get-Content -Raw (Join-Path $loop2 'WATCHERS/reviewer.log')) -match 'attempt published') -and
    ([regex]::Match((Looper status $loop2), '(?m)^NEXT: (\w+)').Groups[1].Value -eq 'worker')
}
Check 'opencode driver: guardrails reach the child, reviewer runs in the task folder (inside or outside the project), own keeps the caller''s rules, no leak' {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'skip' }   # drivers need PowerShell 7
    $proj5 = Join-Path $Scratch 'oc'; $loop5 = Join-Path $proj5 '.looper'
    $record = Join-Path $Scratch 'oc-env.txt'; $argsRecord = Join-Path $Scratch 'oc-args.txt'
    # Drivers read CONTEXT paths with PowerShell, so these tasks come from the ps1 helper in both modes.
    function Oc { & $shell -NoProfile -ExecutionPolicy Bypass -File $ps1Helper @args | Out-Null }
    $outsideLoop = Join-Path $Scratch 'oc-tasks/median'   # a task folder outside the project
    foreach ($l in $loop5, $outsideLoop) {
        Oc new $l -Project $proj5
        [IO.File]::WriteAllText((Join-Path $l 'EXCHANGE/HANDOFF.next.md'), "Request: review`nCandidate: $l`n")
        Oc publish $l handoff
    }
    if ($IsWindows) {   # a fake opencode that records the rules and arguments it was given
        $fake = Join-Path $Scratch 'fake-opencode.cmd'
        Set-Content -LiteralPath $fake -Value "@`"$shell`" -NoProfile -Command `"[IO.File]::AppendAllText('$record', [string]`$env:OPENCODE_PERMISSION + [char]10)`"", "@echo %*>>`"$argsRecord`""
    } else {
        $fake = Join-Path $Scratch 'fake-opencode'
        Set-Content -LiteralPath $fake -Value "#!/bin/sh`nprintf '%s\n' `"`$OPENCODE_PERMISSION`" >> '$record'`nprintf '%s\n' `"`$*`" >> '$argsRecord'"
        & chmod +x $fake
    }
    $env:OPENCODE_PERMISSION = 'caller'
    try {
        foreach ($p in 'looper', 'own') { & $opencodeRun -Loop $loop5 -OpenCode $fake -Permission $p -Once -MaxFailures 1 | Out-Null }
        & $opencodeRun -Loop $outsideLoop -OpenCode $fake -Once -MaxFailures 1 | Out-Null
        $lines = @(Get-Content $record); $argLines = @(Get-Content $argsRecord)
        $projRule = [regex]::Escape(([IO.Path]::GetFullPath($proj5)).Replace('\', '/') + '/**')
        $inside = @(($lines[0] | ConvertFrom-Json).edit.PSObject.Properties | Where-Object Value -eq 'allow' | ForEach-Object Name)
        $outside = @(($lines[2] | ConvertFrom-Json).edit.PSObject.Properties | Where-Object Value -eq 'allow' | ForEach-Object Name)
        # OpenCode's wildcard: * matches anything. A rule must hit this task's files, never a look-alike.
        function Hits([string[]]$Rules, [string]$Path) { @($Rules | Where-Object { $Path.Replace('\', '/') -like $_.Replace('\', '/') }).Count -gt 0 }
        $own = ([IO.Path]::GetFullPath($loop5)).Replace('\', '/')
        ($lines.Count -eq 3) -and ($lines[1] -eq 'caller') -and ($env:OPENCODE_PERMISSION -eq 'caller') -and
        (Hits $inside "$own/EXCHANGE/REVIEW.next.md") -and (Hits $inside "$own/WATCHERS/scratch/probe.ps1") -and
        -not (Hits $inside "$own/EXCHANGE/REVIEW.md") -and -not (Hits $inside "$proj5/sub/.looper/TASK.md") -and
        (Hits $outside "$([IO.Path]::GetFullPath($outsideLoop))/TASK.md") -and -not (Hits $outside "$Scratch/oc-tasks/othermedian/TASK.md") -and
        @($inside + $outside | Where-Object { $_.StartsWith('*') }).Count -eq 0 -and ($lines[2] -match $projRule) -and
        ($argLines[0] -match ('--dir "?' + [regex]::Escape([IO.Path]::GetFullPath($loop5))))
    } finally { Remove-Item Env:OPENCODE_PERMISSION -ErrorAction SilentlyContinue }
}
Check 'claude-code driver: -Local reaches the child and leaves the caller''s ANTHROPIC_* settings untouched' {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'skip' }   # drivers need PowerShell 7
    $record = Join-Path $Scratch 'cc-env.txt'; $loop6 = Join-Path $Scratch 'cc/.looper'
    & $shell -NoProfile -File $ps1Helper new $loop6 -Project (Join-Path $Scratch 'cc') | Out-Null
    [IO.File]::WriteAllText((Join-Path $loop6 'EXCHANGE/HANDOFF.next.md'), "Request: review`nCandidate: cc`n")
    & $shell -NoProfile -File $ps1Helper publish $loop6 handoff | Out-Null
    if ($IsWindows) {
        $fake = Join-Path $Scratch 'fake-claude.cmd'
        Set-Content -LiteralPath $fake -Value "@`"$shell`" -NoProfile -Command `"[IO.File]::AppendAllText('$record', [string]`$env:ANTHROPIC_BASE_URL + [char]10)`""
    } else {
        $fake = Join-Path $Scratch 'fake-claude'
        Set-Content -LiteralPath $fake -Value "#!/bin/sh`nprintf '%s\n' `"`$ANTHROPIC_BASE_URL`" >> '$record'"
        & chmod +x $fake
    }
    $saved = $env:ANTHROPIC_BASE_URL, $env:OLLAMA_HOST
    $env:ANTHROPIC_BASE_URL = 'caller'; $env:OLLAMA_HOST = $null
    try {
        & (Join-Path $repo 'drivers/claude-code/run.ps1') -Loop $loop6 -Claude $fake -Local fake-model -Once -MaxFailures 1 | Out-Null
        (@(Get-Content $record) -join ',') -eq 'http://localhost:11434' -and ($env:ANTHROPIC_BASE_URL -eq 'caller')
    } finally { $env:ANTHROPIC_BASE_URL, $env:OLLAMA_HOST = $saved }
}
Check 'replay after done: an old handoff text cannot reopen and inherit a PASS' {
    Draft HANDOFF "Request: review`nCandidate: value.txt = 2 (repaired)`n"
    $null = Looper publish $loop handoff
    $refused = $code -ne 0
    Remove-Item (Join-Path $loop 'EXCHANGE/HANDOFF.next.md') -ErrorAction SilentlyContinue
    $refused -and ((Next) -eq 'done')
}
# Lifecycle hygiene: reuse, clean, and driver sessions (fake agent, no model).
Check 'reuse: new on an existing task folder points to it instead of creating another' {
    $out = Looper new $loop
    ($code -ne 0) -and ($out -match 'already a Looper task')
}
$loop4 = Join-Path $Scratch 'sessions/.looper'
$null = Looper new $loop4 -Project (Join-Path $Scratch 'sessions')
$w4 = Join-Path $loop4 'WATCHERS'
Check 'clean: removes runtime files, keeps the record' {
    [IO.File]::WriteAllText((Join-Path $loop4 'EXCHANGE/HANDOFF.next.md'), "Request: review`nCandidate: s1`n")
    $null = Looper publish $loop4 handoff
    $junk = 'WATCHERS/reviewer.session', 'WATCHERS/reviewer-last.txt', 'WATCHERS/reviewer.lock', 'EXCHANGE/REVIEW.next.md', 'EXCHANGE/.REVIEW.md.dead.tmp', 'HISTORY/.002_HANDOFF.md.dead.tmp'
    foreach ($j in $junk) { [IO.File]::WriteAllText((Join-Path $loop4 $j), 'x') }
    New-Item -ItemType Directory -Force -Path (Join-Path $w4 'scratch/probe') | Out-Null
    [IO.File]::WriteAllText((Join-Path $w4 'scratch/probe/copy.txt'), 'x')
    [IO.File]::WriteAllText((Join-Path $w4 'reviewer.log'), "log`n")
    $before = Looper status $loop4
    $out = Looper clean $loop4
    $left = @($junk | Where-Object { Test-Path (Join-Path $loop4 $_) })
    ($code -eq 0) -and ($left.Count -eq 0) -and -not (Test-Path (Join-Path $w4 'scratch')) -and (Test-Path (Join-Path $w4 'reviewer.log')) -and (Test-Path (Join-Path $w4 'README.md')) -and
    (Test-Path (Join-Path $loop4 'HISTORY/001_HANDOFF.md')) -and ((Looper status $loop4) -eq $before)
}
Check 'clean: refuses while a driver holds its lock, and deletes nothing' {
    # sh without flock(1): Git Bash checks the Windows lock directly; elsewhere it refuses.
    [IO.File]::WriteAllText((Join-Path $w4 'reviewer.session'), 'x')
    New-Item -ItemType Directory -Force -Path (Join-Path $w4 'scratch') | Out-Null
    [IO.File]::WriteAllText((Join-Path $w4 'scratch/in-progress.txt'), 'x')
    $lock = [IO.File]::Open((Join-Path $w4 'reviewer.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { $null = Looper clean $loop4; $held = $code } finally { $lock.Dispose() }
    $kept = (Test-Path (Join-Path $w4 'reviewer.session')) -and (Test-Path (Join-Path $w4 'scratch/in-progress.txt'))
    $null = Looper clean $loop4   # released: cleans (sh without flock outside Windows still refuses)
    ($held -ne 0) -and $kept
}
Check 'publish: an absolute draft path works, including a drive letter and spaces' {
    $d = Join-Path $Scratch 'draft dir'; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $abs = Join-Path $d 'custom draft.md'
    [IO.File]::WriteAllText($abs, "Request: review`nCandidate: custom draft`n")
    $null = Looper publish $loop4 handoff -Draft $abs; $first = $code
    [IO.File]::WriteAllText($abs, "Request: review`nCandidate: custom draft, forward slashes`n")
    $null = Looper publish $loop4 handoff -Draft ($abs -replace '\\', '/')
    ($first -eq 0) -and ($code -eq 0) -and (Test-Path $abs)
}
Check 'skill build: replaces only a generated package, never the repository (even through a link)' {
    # Disposable copies, so a failed guard can only delete a copy. Every refused output is named
    # "looper", so only this guard (not the name rule) can refuse it.
    function Copy-Repo([string]$To) {
        foreach ($d in 'integrations/skill', 'template', 'prompts', 'tools', 'drivers', 'docs') {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $To $d)) | Out-Null
            Copy-Item -Recurse -LiteralPath (Join-Path $repo $d) -Destination (Join-Path $To $d)
        }
        Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $To
        Join-Path $To 'integrations/skill/build.ps1'
    }
    function Build([string]$Script, [string]$Out) {
        $ErrorActionPreference = 'Continue'; $null = & $shell -NoProfile -ExecutionPolicy Bypass -File $Script -Out $Out 2>&1; $ErrorActionPreference = 'Stop'
        $LASTEXITCODE
    }
    $g = Join-Path $Scratch 'guard'
    $build = Copy-Repo (Join-Path $g 'real/looper')
    $linkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }   # a junction needs no admin rights
    New-Item -ItemType $linkType -Path (Join-Path $g 'alias') -Target (Join-Path $g 'real') | Out-Null
    $inner = Copy-Repo (Join-Path $g 'outer/looper/repo')
    $other = Join-Path $g 'other/looper'; New-Item -ItemType Directory -Force -Path $other | Out-Null; Set-Content (Join-Path $other 'keep.txt') 'x'
    $refused = @(
        ((Build $build (Join-Path $g 'real/looper')) -ne 0),    # the repository itself
        ((Build $build (Join-Path $g 'alias/looper')) -ne 0),   # the repository through a linked parent
        ((Build $inner (Join-Path $g 'outer/looper')) -ne 0),   # a folder containing the repository
        ((Build $build $other) -ne 0)                           # an unrelated folder
    )
    $kept = (Test-Path -LiteralPath $build) -and (Test-Path -LiteralPath $inner) -and (Test-Path (Join-Path $other 'keep.txt'))
    $pkg = Join-Path $g 'installed/looper'
    $rebuilt = ((Build $build $pkg) -eq 0) -and ((Build $build $pkg) -eq 0) -and (Test-Path (Join-Path $pkg 'SKILL.md'))   # a generated package is replaced
    # A genuine package that later came to hold a checkout: building from that checkout into the
    # package (directly, and through a linked parent) must refuse and keep the checkout.
    $held = Join-Path $g 'held/looper'
    $null = Build $build $held
    $nested = Copy-Repo (Join-Path $held 'source checkout')
    New-Item -ItemType $linkType -Path (Join-Path $g 'heldalias') -Target (Join-Path $g 'held') | Out-Null
    $heldRefused = ((Build $nested $held) -ne 0) -and ((Build $nested (Join-Path $g 'heldalias/looper')) -ne 0) -and (Test-Path -LiteralPath $nested) -and
        (Test-Path (Join-Path $held 'SKILL.md')) -and @(Get-ChildItem (Split-Path -Parent $nested) -Force -Filter '.build-guard-*').Count -eq 0
    (-not ($refused -contains $false)) -and $kept -and $rebuilt -and $heldRefused
}
$fakeAgent = Join-Path $Scratch 'fake-agent.ps1'
Set-Content -LiteralPath $fakeAgent -Value @"
param([string]`$Mode, [string]`$Id)
if (`$Mode -eq 'resume' -and `$Id -eq 'gone') { Write-Output 'Error: no rollout found for thread id gone'; exit 1 }
if (-not `$Id) { `$Id = 'sess-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
Write-Output "session id: `$Id"
if (Test-Path (Join-Path '$w4' 'fake-silent')) { exit 0 }
`$h = [regex]::Match(((& '$ps1Helper' status '$loop4') -join "``n"), '(?m)^handoff: (\d+ [0-9a-f]{12})').Groups[1].Value
[IO.File]::WriteAllText((Join-Path '$loop4' 'EXCHANGE/REVIEW.next.md'), "Verdict: PASS``nHandoff: `$h``n")
& '$ps1Helper' publish '$loop4' review | Out-Null
"@
function Invoke-FakeDriver {
    & $agentLoop -Loop $loop4 -Role reviewer -Exe $shell -Session resume -Once `
        -Arguments '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeAgent, 'fresh' `
        -ResumeArguments '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeAgent, 'resume', '{SESSION}' `
        -SessionPattern '(?m)^session id: (\S+)' -ResumeFailurePattern 'no rollout found' | Out-Null
    $LASTEXITCODE
}
function Publish-Handoff4([string]$Text) {
    [IO.File]::WriteAllText((Join-Path $loop4 'EXCHANGE/HANDOFF.next.md'), $Text)
    & $shell -NoProfile -ExecutionPolicy Bypass -File $ps1Helper publish $loop4 handoff | Out-Null
}
$sessionFile4 = Join-Path $w4 'reviewer.session'
Check 'session: first run starts fresh and saves the session id (runtime state only)' {
    $null = Invoke-FakeDriver
    $id = if (Test-Path $sessionFile4) { (Get-Content -Raw $sessionFile4).Trim() } else { '' }
    $script:firstSession = $id
    ($id -like 'sess-*') -and ((Get-Content -Raw (Join-Path $w4 'reviewer.log')) -match 'attempt start \(fresh\)')
}
Check 'session: next handoff resumes the saved session' {
    Publish-Handoff4 "Request: review`nCandidate: s2`n"
    $null = Invoke-FakeDriver
    ((Get-Content -Raw (Join-Path $w4 'reviewer.log')) -match "attempt start \(resume $script:firstSession\)") -and
    ([regex]::Match((Looper status $loop4), '(?m)^NEXT: (\w+)').Groups[1].Value -eq 'worker')
}
Check 'session: an attempt that publishes nothing keeps its session (not an explicit resume failure)' {
    Publish-Handoff4 "Request: review`nCandidate: s3`n"
    [IO.File]::WriteAllText((Join-Path $w4 'fake-silent'), 'x')
    $null = Invoke-FakeDriver
    Remove-Item (Join-Path $w4 'fake-silent')
    ((Get-Content -Raw $sessionFile4).Trim() -eq $script:firstSession) -and
    ([regex]::Match((Looper status $loop4), '(?m)^NEXT: (\w+)').Groups[1].Value -eq 'reviewer')
}
Check 'session: an explicitly unavailable session cold-starts in the same attempt and settles the handoff' {
    [IO.File]::WriteAllText($sessionFile4, 'gone')
    $null = Invoke-FakeDriver
    $log = Get-Content -Raw (Join-Path $w4 'reviewer.log')
    ($log -match 'resume unavailable \(gone\).*cold start') -and ((Get-Content -Raw $sessionFile4).Trim() -like 'sess-*') -and
    ([regex]::Match((Looper status $loop4), '(?m)^NEXT: (\w+)').Groups[1].Value -eq 'worker')
}
Check 'session: deleting all session state still leaves a recoverable task' {
    Publish-Handoff4 "Request: review`nCandidate: s4`n"
    Remove-Item $sessionFile4
    $null = Invoke-FakeDriver
    [regex]::Match((Looper status $loop4), '(?m)^NEXT: (\w+)').Groups[1].Value -eq 'worker'
}
Check 'lifecycle: at done the driver removes its session and last-output files' {
    [IO.File]::WriteAllText((Join-Path $loop4 'FINAL_REPORT.md'), "# FINAL REPORT`ndone`n")
    Start-Sleep -Milliseconds 50
    Publish-Handoff4 "Request: final review`nCandidate: s4 + report`n"
    $null = Invoke-FakeDriver
    $code2 = Invoke-FakeDriver
    ($code2 -eq 0) -and -not (Test-Path $sessionFile4) -and -not (Test-Path (Join-Path $w4 'reviewer-last.txt')) -and
    ([regex]::Match((Looper status $loop4), '(?m)^NEXT: (\w+)').Groups[1].Value -eq 'done')
}
# Codex adapter, Windows only: re-owning sandbox-created files must never lose or change state.
$reown = Join-Path $repo 'drivers/codex/reown.ps1'
function Get-Temps { @(Get-ChildItem -LiteralPath $loop -Recurse -Force -Filter '*.tmp' | ForEach-Object FullName) -join ',' }
function Get-Snapshot {
    Get-ChildItem -LiteralPath $loop -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\/]WATCHERS[\/]' } |
        ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.FullName, (Sha $_.FullName), $_.LastWriteTimeUtc.Ticks, $_.CreationTimeUtc.Ticks }
}
Check 'codex re-own: files re-created with identical content and times; HISTORY untouched; status unchanged' {
    if (($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) -or -not (Get-Command Get-Acl -ErrorAction SilentlyContinue)) { return 'skip' }
    $statusBefore = Looper status $loop
    $tempsBefore = Get-Temps
    $before = @(Get-Snapshot)
    $out = & $reown -Folder $loop -OwnerPattern '.'
    $after = @(Get-Snapshot)
    $strip = { param($s) ($s | ForEach-Object { ($_ -split '\|')[0..2] -join '|' }) -join "`n" }
    $histBefore = @($before | Where-Object { $_ -match '[\/]HISTORY[\/]' }) -join "`n"
    $histAfter = @($after | Where-Object { $_ -match '[\/]HISTORY[\/]' }) -join "`n"
    ((& $strip $before) -eq (& $strip $after)) -and ($histBefore -eq $histAfter) -and ($out -match 're-created') -and
    ((Looper status $loop) -eq $statusBefore) -and ((Get-Temps) -eq $tempsBefore)
}
Check 'codex re-own: if the replace fails, the original stays in place and no temp file is left' {
    if (($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) -or -not (Get-Command Get-Acl -ErrorAction SilentlyContinue)) { return 'skip' }
    $review = Join-Path $loop 'EXCHANGE/REVIEW.md'
    $hash = Sha $review
    $tempsBefore = Get-Temps
    $hold = [IO.File]::Open($review, 'Open', 'Read', 'Read')   # readable, but cannot be replaced
    try { $out = & $reown -Folder $loop -OwnerPattern '.' } finally { $hold.Dispose() }
    ($out -match 'could not re-create REVIEW.md') -and ((Sha $review) -eq $hash) -and ((Get-Temps) -eq $tempsBefore)
}
Check 'provider-neutral core: template, prompts, tools and contract name no provider' {
    $core = 'template', 'prompts', 'tools' | ForEach-Object { Join-Path $repo $_ }
    $files = @(Get-ChildItem $core -Recurse -File) + @(Get-Item (Join-Path $repo 'docs/contract.md'))
    @($files | Select-String -Pattern 'codex|claude|openai|anthropic|opencode|grok').Count -eq 0
}
Check 'privacy: no real user-profile paths in shipped files, docs, examples or evidence' {
    # Evidence keeps paths as C:\Users\<user>\...; anything else under C:\Users\ would leak a username.
    $dirs = 'template', 'prompts', 'tools', 'drivers', 'integrations', 'docs', 'examples', 'tests/evidence', '.github' |
        ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path $_ }
    $top = @('README.md', 'CONTEXT.md', 'CHANGELOG.md', 'CONTRIBUTING.md' | ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path $_ })   # CONTEXT.md may be absent in an export
    $files = @(Get-ChildItem $dirs -Recurse -File -Force) + @($top | ForEach-Object { Get-Item $_ })
    @($files | Select-String -Pattern '[A-Za-z]:[\\/]Users[\\/](?!<user>)[^\\/<>\s]+[\\/]').Count -eq 0
}

Write-Output ''
if ($script:failed) { Write-Output "$script:failed check(s) FAILED. Scratch kept at $Scratch"; exit 1 }
Remove-Item -Recurse -Force $Scratch
Write-Output 'All acceptance checks passed.'
