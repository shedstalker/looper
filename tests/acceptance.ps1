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

function Start-TestProcess([string]$Program, [string[]]$Arguments, [string]$Dir) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Program)
    if ($Dir) { $psi.WorkingDirectory = $Dir }
    $psi.Arguments = ($Arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    [pscustomobject]@{ Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
}
function Start-Publish([string]$TaskFolder, [string]$DraftPath, [string]$Dir) {
    if ($helperKind -eq 'sh') { Start-TestProcess (Get-Command sh).Source @($helperPath, 'publish', $TaskFolder, 'handoff', '--draft', $DraftPath) $Dir }
    else { Start-TestProcess $shell @('-NoProfile', '-File', $helperPath, 'publish', $TaskFolder, 'handoff', '-Draft', $DraftPath) $Dir }
}
function Finish-Publish($Child) {
    if (-not $Child.Process.WaitForExit(20000)) { throw 'publish did not finish within 20 s' }
    if ($Child.Process.ExitCode -ne 0) { throw "publish failed: $($Child.Err.Result)" }
    $Child.Out.Result
}
function Stop-TestProcess($Child) {
    if ($Child -and -not $Child.Process.HasExited) { $Child.Process.Kill(); $Child.Process.WaitForExit() }
    if ($Child) { $Child.Process.Dispose() }
}
function Test-PublishExclusion([string]$TaskFolder) {
    $draftPath = Join-Path $TaskFolder 'held draft.md'
    [IO.File]::WriteAllText($draftPath, "Request: lock exclusion $TaskFolder`n")
    $lock = [IO.File]::Open((Join-Path $TaskFolder 'EXCHANGE/.publish.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $child = $null
    try {
        # Relative arguments must survive the sh re-run without a cwd change. The child starts in the
        # task folder: Resolve-Path -Relative across drives (CI: repo on D:, temp on C:) is not a path on 5.1.
        $child = Start-Publish $TaskFolder 'held draft.md' $TaskFolder
        $blocked = -not $child.Process.WaitForExit(2000)
        $unpublished = -not (Test-Path (Join-Path $TaskFolder 'HISTORY/001_HANDOFF.md'))
        $lock.Dispose()
        $out = Finish-Publish $child
        $blocked -and $unpublished -and ($out -match 'published handoff 001') -and
            ((Sha $draftPath) -eq (Sha (Join-Path $TaskFolder 'HISTORY/001_HANDOFF.md')))
    } finally { $lock.Dispose(); Stop-TestProcess $child }
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
foreach ($name in 'research', 'attach', 'attach-dots', 'driver', 'sessions', 'oc', 'cc', 'stdin', 'bom-publish-ps1', 'bom-publish-sh') {
    New-Item -ItemType Directory -Path (Join-Path $Scratch $name) | Out-Null
}
$loop = Join-Path $project '.looper'
Write-Output "Scratch: $Scratch  (PowerShell $($PSVersionTable.PSVersion), helper tools/looper.$Helper)"

Check 'bootstrap: new creates the task folder' {
    $out = Looper new $loop -Task demo -Project $project
    ($code -eq 0) -and (Test-Path (Join-Path $loop 'EXCHANGE/HANDOFF.md')) -and ($out -match 'You are the REVIEWER for the Looper task at') -and
    ((Get-Content -Raw (Join-Path $loop 'CONTEXT.md')) -notmatch '\{\{')
}
Check 'bootstrap: Git Bash writes native task, project and Looper home paths' {
    if ($helperKind -ne 'sh' -or $env:OS -ne 'Windows_NT') { return 'skip' }
    $uname = & sh -c 'uname -s'
    if ($uname -notmatch '^(MINGW|MSYS|CYGWIN)') { return 'skip' }
    $context = [IO.File]::ReadAllText((Join-Path $loop 'CONTEXT.md'))
    foreach ($field in @('Task folder', $loop), @('Project / source', $project), @('Looper home', $repo)) {
        $value = [regex]::Match($context, ('(?m)^- ' + [regex]::Escape($field[0]) + ': `([^`]+)`')).Groups[1].Value
        if ($value -notmatch '^[A-Za-z]:/' -or -not [IO.Directory]::Exists($value) -or
            [IO.Path]::GetFullPath($value) -ne [IO.Path]::GetFullPath($field[1])) { return $false }
    }
    $true
}
Check 'publish: UTF-16 LE and BE drafts are refused with UTF-8 guidance and publish nothing' {
    $folder = Join-Path $Scratch 'utf16-task'
    $null = Looper new $folder -Project $project
    $before = @(Sha (Join-Path $folder 'EXCHANGE/HANDOFF.md'); Sha (Join-Path $folder 'EXCHANGE/REVIEW.md')) -join ','
    foreach ($encoding in [Text.Encoding]::Unicode, [Text.Encoding]::BigEndianUnicode) {
        foreach ($kind in 'HANDOFF', 'REVIEW') {
            $draft = Join-Path $folder "EXCHANGE/$kind.next.md"
            [IO.File]::WriteAllBytes($draft, [byte[]]($encoding.GetPreamble() + $encoding.GetBytes("Request: UTF-16`n")))
            $out = Looper publish $folder $kind
            if ($code -eq 0 -or $out -notmatch 'save it as UTF-8' -or -not (Test-Path -LiteralPath $draft)) { return $false }
        }
    }
    $after = @(Sha (Join-Path $folder 'EXCHANGE/HANDOFF.md'); Sha (Join-Path $folder 'EXCHANGE/REVIEW.md')) -join ','
    ($before -eq $after) -and @(Get-ChildItem (Join-Path $folder 'HISTORY') -Force).Count -eq 0
}
Check 'arguments: unknown commands, invalid ranges, roles and kinds are refused' {
    foreach ($command in 'statuz', '') {
        $null = Looper $command $loop
        if ($code -eq 0) { return $false }
    }
    if ($helperKind -eq 'sh') {
        foreach ($helpArgs in @(), @('help'), @('-h'), @('--help')) {
            $out = Looper @helpArgs
            if ($code -ne 0 -or $out -notmatch 'looper.sh new') { return $false }
        }
    }
    foreach ($bad in @('-TimeoutMinutes', '0'), @('-TimeoutMinutes', '10081'), @('-TimeoutMinutes', 'nope'),
                    @('-TimeoutMinutes', '1e1'), @('-TimeoutMinutes', '.5'), @('-PollSeconds', '1.5'), @('-PollSeconds', '\061'), @('-PollSeconds', "1`n"),
                    @('-PollSeconds', '0'), @('-PollSeconds', '3601'), @('-PollSeconds', 'nope'),
                    @('-For', 'neither'), @('-For', ''), @('neither'), @(''),
                    @('handoff', 'review'), @('-PollSeconds', '1', '-PollSeconds', '2')) {   # a stray word or a repeat never replaces a value
        # Windows PowerShell 5.1 drops an empty argument to a native program, so it cannot send ''.
        if ($bad[0] -eq '' -and $PSVersionTable.PSEdition -eq 'Desktop') { continue }
        $null = Looper status $loop @bad
        if ($code -eq 0) { return $false }
    }
    foreach ($limits in @('0.01', '1'), @('10080', '3600')) {
        $null = Looper status $loop -TimeoutMinutes $limits[0] -PollSeconds $limits[1]
        if ($code -ne 0) { return $false }
    }
    $true
}
Check 'bootstrap: missing project is refused before creating any task folder' {
    $missing = Join-Path $Scratch 'missing-project'
    foreach ($target in (Join-Path $missing '.looper'), (Join-Path $Scratch 'missing-parent/task')) {
        $out = Looper new $target -Project $missing
        if ($code -eq 0 -or $out -notmatch 'no project folder' -or (Test-Path (Split-Path -Parent $target))) { return $false }
    }
    $true
}
Check 'case: command, role and kind words are case-insensitive' {
    $taskFolder = Join-Path $Scratch 'case-task'
    $null = Looper NeW $taskFolder -Project $project
    if ($code -ne 0) { return $false }
    $out = Looper WaIt $taskFolder -For WoRkEr -TimeoutMinutes 0.01
    if ($code -ne 0 -or $out -notmatch 'DUE worker') { return $false }
    [IO.File]::WriteAllText((Join-Path $taskFolder 'EXCHANGE/HANDOFF.next.md'), "Request: case parity`n")
    $null = Looper PuBlIsH $taskFolder HaNdOfF
    if ($code -ne 0) { return $false }
    $out = Looper StAtUs $taskFolder
    $id = [regex]::Match($out, '(?m)^handoff: (\d+ [0-9a-f]{12})').Groups[1].Value
    if ($code -ne 0 -or -not $id) { return $false }
    $null = Looper WaIt $taskFolder -For ReViEwEr -TimeoutMinutes 0.01
    if ($code -ne 0) { return $false }
    [IO.File]::WriteAllText((Join-Path $taskFolder 'EXCHANGE/REVIEW.next.md'), "Handoff: $id`nVerdict: PASS`n")
    $null = Looper PuBlIsH $taskFolder ReViEw
    if ($code -ne 0) { return $false }
    $out = Looper StAtUs $taskFolder
    if ($code -ne 0 -or $out -notmatch 'NEXT: worker') { return $false }
    $null = Looper ClEaN $taskFolder
    $code -eq 0
}
Check 'verdict: first inline form wins over heading form; otherwise first heading wins' {
    $taskFolder = Join-Path $Scratch 'verdict-task'
    $null = Looper new $taskFolder -Project $project
    [IO.File]::WriteAllText((Join-Path $taskFolder 'FINAL_REPORT.md'), "Report`n")
    [IO.File]::WriteAllText((Join-Path $taskFolder 'EXCHANGE/HANDOFF.next.md'), "Request: final review`n")
    $null = Looper publish $taskFolder handoff
    $id = [regex]::Match((Looper status $taskFolder), '(?m)^handoff: (\d+ [0-9a-f]{12})').Groups[1].Value
    foreach ($sample in @("# Verdict`n> BLOCKED`nVerdict: PASS`n", 'PASS', 'done'),
                       @("Verdict: REPAIR`nVerdict: PASS`n", 'REPAIR', 'worker'),
                       @("# Verdict`n> BLOCKED`n# Verdict`n> PASS`n", 'BLOCKED', 'worker'),
                       @("# Verdict`nPASS`nVerdict: REPAIR`n", 'PASS', 'done'),
                       @("## Verdict`n``Verdict: PASS```nVerdict: REPAIR`n", 'REPAIR', 'worker'),
                       @("Verdict`n: REPAIR`nVerdict: PASS`n", 'REPAIR', 'worker'),
                       @("## Verdict`n>`nPASS`n", 'PASS', 'done'),
                       # One ASCII grammar in both helpers: é ends the word, a no-break space is not a space,
                       # and only A-Z fold (not İ or the Kelvin sign).
                       @("Verdict: PASS$([char]0xE9)`nVerdict: REPAIR`n", 'PASS', 'done'),
                       @("Verd$([char]0x130)ct: PASS`nVerdict: REPAIR`n", 'REPAIR', 'worker'),
                       @("Verdict: PASS$([char]0x130)`nVerdict: REPAIR`n", 'PASS', 'done'),
                       @("Verdict: BLOC$([char]0x212A)ED`nVerdict: REPAIR`n", 'REPAIR', 'worker'),
                       @("Verdict:$([char]0xA0)PASS`n", 'ANSWER', 'worker')) {
        [IO.File]::WriteAllText((Join-Path $taskFolder 'EXCHANGE/REVIEW.next.md'), "Handoff: $id`n$($sample[0])")
        $published = Looper publish $taskFolder review
        if ($code -ne 0 -or $published -notmatch "review $($sample[1]) for") { return $false }
        $out = Looper status $taskFolder
        if ($code -ne 0 -or $out -notmatch "review:  $($sample[1]) for" -or $out -notmatch "NEXT: $($sample[2])") { return $false }
    }
    # é ends the hash in both editions, so this review binds.
    [IO.File]::WriteAllText((Join-Path $taskFolder 'EXCHANGE/REVIEW.next.md'), "Handoff: $id$([char]0xE9)`nVerdict: REPAIR`n")
    $published = Looper publish $taskFolder review
    ($code -eq 0) -and ($published -match 'review REPAIR for')
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
Check 'bootstrap: a task folder with a non-ASCII name is excluded too' {
    if (-not $gitOk) { return 'skip' }
    # A non-UTF-8 console code page (the Windows default) is what corrupted git's output.
    $saved = $null; try { $saved = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(437) } catch { $saved = $null }
    try { $null = Looper new (Join-Path $project "caf$([char]0xE9)-task/.looper") -Project $project; $newCode = $code }
    finally { if ($saved) { try { [Console]::OutputEncoding = $saved } catch { } } }
    $ErrorActionPreference = 'Continue'; $st = & git -C $project status --porcelain 2>$null; $ErrorActionPreference = 'Stop'
    ($newCode -eq 0) -and (@($st | Where-Object { $_ -match '-task' }).Count -eq 0)
}
Check 'bootstrap (#4): git excludes literal task folder names without duplicate entries' {
    if (-not $gitOk) { return 'skip' }
    $names = @('.looper[final]')
    if ($env:OS -ne 'Windows_NT') { $names += '.looper*final' }
    if ($IsLinux) { $names += '.looper[A]', '.looper[a]' }   # case-sensitive: each needs its own entry
    foreach ($name in $names) {
        $taskFolder = Join-Path $project $name
        $null = Looper new $taskFolder -Project $project
        if ($code -ne 0) { return $false }
        $ErrorActionPreference = 'Continue'
        & git -C $project check-ignore -q -- "$name/CONTEXT.md"
        $ignored = $LASTEXITCODE -eq 0
        $ErrorActionPreference = 'Stop'
        $exclude = Join-Path $project '.git/info/exclude'
        $before = [IO.File]::ReadAllText($exclude)
        # new refuses an existing task; recreating it also exercises the exclude duplicate check.
        Remove-Item -LiteralPath $taskFolder -Recurse -Force
        $null = Looper new $taskFolder -Project $project
        if (-not $ignored -or $code -ne 0 -or [IO.File]::ReadAllText($exclude) -cne $before) { return $false }
    }
    $true
}
Check 'bootstrap: new never overwrites an existing folder' { $null = Looper new $loop; $code -ne 0 }
Check 'fresh folder: NEXT is worker' { (Next) -eq 'worker' }
Check 'publish: four concurrent drafts get distinct HISTORY numbers matching their output' {
    $taskFolder = Join-Path $Scratch 'concurrent/.looper'
    $null = Looper new $taskFolder
    $children = @()
    try {
        foreach ($i in 1..4) {
            $d = Join-Path $taskFolder "draft$i.md"
            [IO.File]::WriteAllText($d, "Request: concurrent candidate $i`n")
            $children += [pscustomobject]@{ Child = (Start-Publish $taskFolder $d); Draft = $d }
        }
        foreach ($entry in $children) {
            $out = Finish-Publish $entry.Child
            if ($out -notmatch 'published handoff (\d{3}) ([0-9a-f]{12})') { throw "bad publish output: $out" }
            $saved = Join-Path $taskFolder "HISTORY/$($Matches[1])_HANDOFF.md"
            $hash = Sha $saved
            if ($hash -ne (Sha $entry.Draft) -or -not $hash.StartsWith($Matches[2])) { throw 'printed number does not match its draft' }
        }
        (@(Get-ChildItem (Join-Path $taskFolder 'HISTORY') -Name | Sort-Object) -join ',') -eq
            '001_HANDOFF.md,002_HANDOFF.md,003_HANDOFF.md,004_HANDOFF.md'
    } finally { foreach ($entry in $children) { Stop-TestProcess $entry.Child } }
}
Check 'publish: waits for a .NET share-none holder, then publishes after release' {
    $taskFolder = Join-Path $Scratch 'held/.looper'
    $null = Looper new $taskFolder
    Test-PublishExclusion $taskFolder
}
Check 'publish: a killed .NET lock holder leaves the next publish unblocked' {
    $taskFolder = Join-Path $Scratch 'killed/.looper'
    $null = Looper new $taskFolder
    $lockPath = (Join-Path $taskFolder 'EXCHANGE/.publish.lock').Replace("'", "''")
    $ready = Join-Path $taskFolder 'ready'
    $holderCode = "`$f = [IO.File]::Open('$lockPath', 'OpenOrCreate', 'ReadWrite', 'None'); [IO.File]::WriteAllText('$($ready.Replace("'", "''"))', 'held'); [Threading.Thread]::Sleep(-1)"
    $holder = Start-TestProcess $shell @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holderCode)))
    $child = $null
    try {
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path $ready)) {
            if ($holder.Process.HasExited -or $wait.Elapsed.TotalSeconds -gt 20) { throw 'holder did not acquire the lock' }
            Start-Sleep -Milliseconds 20
        }
        $holder.Process.Kill(); $holder.Process.WaitForExit()
        $d = Join-Path $taskFolder 'draft.md'; [IO.File]::WriteAllText($d, "Request: after holder death`n")
        $child = Start-Publish $taskFolder $d
        ((Finish-Publish $child) -match 'published handoff 001') -and (Test-Path -LiteralPath $lockPath)
    } finally { Stop-TestProcess $holder; Stop-TestProcess $child }
}
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

Check 'hash (#3): backslash paths refuse handoff replay and attachments record the true SHA-256' {
    if ($helperKind -ne 'sh' -or $env:OS -eq 'Windows_NT') { return 'skip' }
    # Join-Path normalises backslashes on Unix; build these literal file names with .NET paths.
    $taskFolder = $Scratch + '/hash\task'
    $null = Looper new $taskFolder
    $draftPath = $taskFolder + '/EXCHANGE/HANDOFF.next.md'
    [IO.File]::WriteAllText($draftPath, "Request: A`n")
    $null = Looper publish $taskFolder handoff; $firstCode = $code
    [IO.File]::WriteAllText($draftPath, "Request: B`n")
    $null = Looper publish $taskFolder handoff; $secondCode = $code
    [IO.File]::WriteAllText($draftPath, "Request: A`n")
    $out = Looper publish $taskFolder handoff
    $refused = $code -ne 0 -and $out -match 'already published as 001'
    $attachment = $Scratch + '/evidence\file.bin'
    [IO.File]::WriteAllBytes($attachment, [byte[]](0, 1, 2, 255))
    [IO.File]::WriteAllText($draftPath, "Request: attachment`n")
    $null = Looper publish $taskFolder handoff -Attach $attachment
    $text = [IO.File]::ReadAllText($taskFolder + '/EXCHANGE/HANDOFF.md')
    $stream = [IO.File]::OpenRead($attachment)   # Get-FileHash's path handling also normalises backslashes
    try { $hash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant() }
    finally { $stream.Dispose() }
    ($firstCode -eq 0) -and ($secondCode -eq 0) -and $refused -and ($code -eq 0) -and
        $text.Contains('- `evidence\file.bin`: 4 bytes, sha256 ' + $hash + "`n")
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
Check 'names are literal: a leading dash, space, glob character or backslash in an attachment or task path, a custom draft differing only in case, -For in any case' {
    $taskFolder = Join-Path $Scratch 'literal/.looper'
    $null = Looper new $taskFolder
    $out = Looper wait $taskFolder -For WORKER -TimeoutMinutes 0.01
    if ($code -ne 0 -or "$out" -cnotmatch 'LOOPER DUE worker') { return $false }
    $out = Looper wait $taskFolder -For REVIEWER -TimeoutMinutes 0.01
    if ($code -ne 3 -or "$out" -cnotmatch 'nothing due for reviewer') { return $false }
    [IO.File]::WriteAllText((Join-Path $docs '-dash.md'), "dash`n")
    $names = @('-dash.md')   # relative, so a cp without -- would read it as an option
    if ($env:OS -ne 'Windows_NT') {
        [IO.File]::WriteAllText((Join-Path $docs 'star*.md'), "star`n")
        [IO.File]::WriteAllText((Join-Path $docs 'starX.md'), "other`n")   # what a glob would also pick
        $names += 'star*.md'
        foreach ($n in ' space.md', 'space.md', "back$([char]92)slash.md") { [IO.File]::WriteAllText([IO.Path]::Combine($docs, $n), "$n`n") }
        $names += ' space.md', "back$([char]92)slash.md"   # a trimmed or split name would pick another file
    }
    # On Linux this is not the default draft (HANDOFF.next.md), so publishing must keep it.
    $draft = Join-Path $taskFolder $(if ($IsLinux) { 'EXCHANGE/HANDOFF.NEXT.MD' } else { 'EXCHANGE/HANDOFF.next.md' })
    [IO.File]::WriteAllText($draft, "Request: literal names`n")
    Push-Location $docs
    try { $null = Looper publish $taskFolder handoff -Draft $draft -Attach ($names -join ',') } finally { Pop-Location }
    $snap = Join-Path $taskFolder 'HISTORY/001_attachments'
    $first = ($code -eq 0) -and (@(Get-ChildItem -LiteralPath $snap -Force).Count -eq $names.Count) -and
        -not @($names | Where-Object { (Sha ([IO.Path]::Combine($snap, $_))) -ne (Sha ([IO.Path]::Combine($docs, $_))) }) -and
        (-not $IsLinux -or (Test-Path -LiteralPath $draft))   # never delete a file other than the default draft
    # The default draft, however it is spelled, is removed after publishing.
    $default = Join-Path $taskFolder 'EXCHANGE/HANDOFF.next.md'
    [IO.File]::WriteAllText($default, "Request: second, via a relative draft path`n")
    Push-Location $taskFolder
    try { $null = Looper publish $taskFolder handoff -Draft './EXCHANGE/HANDOFF.next.md' } finally { Pop-Location }
    $second = $first -and ($code -eq 0) -and -not (Test-Path -LiteralPath $default)
    if ($IsLinux) {
        # Distinct folders whose names are Unicode-equal (NFC, NFD): a draft in the other one is never the default.
        $nfc = Join-Path $Scratch "uni/caf$([char]0xE9)/.looper"
        $nfd = Join-Path $Scratch "uni/cafe$([char]0x301)/.looper"
        $null = Looper new $nfc
        $null = Looper new $nfd
        $foreign = Join-Path $nfd 'EXCHANGE/HANDOFF.next.md'
        [IO.File]::WriteAllText($foreign, "Request: from the other folder`n")
        $null = Looper publish $nfc handoff -Draft $foreign
        $second = $second -and ($code -eq 0) -and [IO.File]::Exists($foreign)
    }
    if ($env:OS -eq 'Windows_NT') { return $second }
    # On Unix a backslash is part of a folder name: a helper works on that folder or refuses, never on a/b.
    $other = Join-Path $Scratch 'bs/a/b/.looper'
    $null = Looper new $other
    $keep = Join-Path $other 'EXCHANGE/REVIEW.next.md'
    [IO.File]::WriteAllText($keep, "another task's draft`n")
    $slashed = [IO.Path]::Combine($Scratch, "bs/a$([char]92)b/.looper")
    $null = Looper new $slashed
    $null = Looper clean $slashed
    $second -and [IO.File]::Exists($keep)
}
Check 'attach (#2): publish replaces an orphan snapshot and removes stale HISTORY temps' {
    $taskFolder = Join-Path $Scratch 'attach-crash/.looper'
    $null = Looper new $taskFolder
    $history = Join-Path $taskFolder 'HISTORY'
    $snap = Join-Path $history '001_attachments'
    [IO.Directory]::CreateDirectory($snap) | Out-Null
    [IO.File]::WriteAllText((Join-Path $snap 'other.txt'), 'left by interrupted publish')
    [IO.File]::WriteAllText((Join-Path $history '.001_HANDOFF.md.123.tmp'), 'partial handoff')
    [IO.File]::WriteAllText((Join-Path $taskFolder 'EXCHANGE/HANDOFF.next.md'), "Request: retry with attachment`n")
    $out = Looper publish $taskFolder handoff -Attach $brief
    $retried = ($code -eq 0) -and ($out -match 'published handoff 001') -and
        ([IO.File]::Exists((Join-Path $history '001_HANDOFF.md'))) -and
        ((Sha (Join-Path $snap 'brief one.md')) -eq (Sha $brief)) -and
        (@(Get-ChildItem -LiteralPath $snap -Force).Count -eq 1) -and
        (@(Get-ChildItem -LiteralPath $history -Force -Filter '.*.tmp').Count -eq 0)
    # A recorded handoff owns its snapshot by number, also as 1_HANDOFF.md: a mismatch is refused, never replaced.
    [IO.File]::WriteAllText((Join-Path $snap 'brief one.md'), 'tampered')
    Move-Item -LiteralPath (Join-Path $history '001_HANDOFF.md') -Destination (Join-Path $history '1_HANDOFF.md')
    Remove-Item -LiteralPath (Join-Path $taskFolder 'EXCHANGE/HANDOFF.md')
    [IO.File]::WriteAllText((Join-Path $taskFolder 'EXCHANGE/HANDOFF.next.md'), "Request: retry with attachment`n")
    $null = Looper publish $taskFolder handoff -Attach $brief
    $refused = $retried -and ($code -ne 0) -and ([IO.File]::ReadAllText((Join-Path $snap 'brief one.md')) -ceq 'tampered')
    # A handoff archive the scan does not read (001_HANDOFF.MD) but a case-insensitive volume equates with
    # the next name: never overwritten, its snapshot never taken for an orphan.
    $caseFolder = Join-Path $Scratch 'attach-case/.looper'
    $null = Looper new $caseFolder
    $caseHistory = Join-Path $caseFolder 'HISTORY'
    [IO.File]::WriteAllText((Join-Path $caseFolder 'EXCHANGE/HANDOFF.next.md'), "Request: first`n")
    $null = Looper publish $caseFolder handoff -Attach $brief
    Move-Item -LiteralPath (Join-Path $caseHistory '001_HANDOFF.md') -Destination (Join-Path $caseHistory 'renaming')
    Move-Item -LiteralPath (Join-Path $caseHistory 'renaming') -Destination (Join-Path $caseHistory '001_HANDOFF.MD')
    $archive = Sha (Join-Path $caseHistory '001_HANDOFF.MD')
    $insensitive = [IO.File]::Exists((Join-Path $caseHistory '001_HANDOFF.md'))
    [IO.File]::WriteAllText((Join-Path $caseFolder 'EXCHANGE/HANDOFF.next.md'), "Request: second`n")
    $null = Looper publish $caseFolder handoff -Attach $brief
    if (-not $insensitive) { return $refused }
    $kept = ($code -ne 0) -and ((Sha (Join-Path $caseHistory '001_HANDOFF.MD')) -eq $archive) -and
        [IO.File]::Exists((Join-Path $caseHistory '001_attachments/brief one.md'))
    # Nor does restoring the archive read as 1_HANDOFF.md overwrite a different 001_HANDOFF.MD.
    Copy-Item -LiteralPath (Join-Path $caseHistory '001_HANDOFF.MD') -Destination (Join-Path $caseHistory '1_HANDOFF.md')
    [IO.File]::WriteAllText((Join-Path $caseHistory '001_HANDOFF.MD'), "another record`n")
    Remove-Item -LiteralPath (Join-Path $caseFolder 'EXCHANGE/HANDOFF.md')
    [IO.File]::WriteAllText((Join-Path $caseFolder 'EXCHANGE/HANDOFF.next.md'), "Request: first`n")
    $null = Looper publish $caseFolder handoff -Attach $brief
    $refused -and $kept -and ($code -ne 0) -and ([IO.File]::ReadAllText((Join-Path $caseHistory '001_HANDOFF.MD')) -ceq "another record`n")
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
Check 'driver: empty arguments reach the child between non-empty arguments' {
    $fake = Join-Path $Scratch 'argument-reader.ps1'
    [IO.File]::WriteAllText($fake, '[Console]::WriteLine(($args | ForEach-Object { "<$_>" }) -join "|")')
    & $agentLoop -Loop $loop2 -Role reviewer -Exe $shell `
        -Arguments '-NoProfile', '-File', $fake, 'before', '', 'after', '' -Once | Out-Null
    ($LASTEXITCODE -eq 6) -and ([IO.File]::ReadAllText((Join-Path $loop2 'WATCHERS/reviewer-last.txt')).Trim() -eq '<before>|<>|<after>|<>')
}
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
Check 'driver: Once without publishing exits 6 after one attempt, leaving work due' {
    $lines = @(Get-Content (Join-Path $loop2 'WATCHERS/reviewer.log')).Count
    & $agentLoop -Loop $loop2 -Role reviewer -Exe $shell -Arguments '-NoProfile', '-Command', 'exit 0' -Once -MaxFailures 1 | Out-Null
    $exitCode = $LASTEXITCODE
    $starts = @(Get-Content (Join-Path $loop2 'WATCHERS/reviewer.log') | Select-Object -Skip $lines | Where-Object { $_ -match 'attempt start' }).Count
    ($exitCode -eq 6) -and ($starts -eq 1) -and ((Looper status $loop2) -match 'NEXT: reviewer')
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
Check 'driver: Once with nothing due exits 7 immediately; watcher exits at its idle limit; a broken task folder is an error' {
    foreach ($once in $true, $false) {
        $args2 = @('-NoProfile', '-File', $agentLoop, '-Loop', $loop2, '-Role', 'reviewer', '-Exe', $shell)
        $args2 += $(if ($once) { @('-Once') } else { @('-IdleExitMinutes', '0.05') })
        $timer = [Diagnostics.Stopwatch]::StartNew(); $child = Start-TestProcess $shell $args2
        try {
            if (-not $child.Process.WaitForExit(60000)) { return $false }
            if ($child.Process.ExitCode -ne $(if ($once) { 7 } else { 0 })) { return $false }
            if ($once -and $timer.Elapsed.TotalSeconds -ge 30) { return $false }   # far below the 60-minute wait
            if ($child.Out.Result -notmatch $(if ($once) { 'nothing due' } else { 'idle 0.05 min; exiting' })) { return $false }
            if (-not $once -and $timer.Elapsed.TotalSeconds -lt 3) { return $false }
        } finally { Stop-TestProcess $child }
    }
    $broken = Join-Path $Scratch 'broken/.looper'
    $null = Looper new $broken
    Remove-Item -LiteralPath (Join-Path $broken 'EXCHANGE') -Recurse -Force
    $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 would turn the child's stderr into an exception
    & $shell -NoProfile -File $agentLoop -Loop $broken -Role reviewer -Exe $shell -Once *> $null
    $code = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    $code -eq 1
}
Check 'driver: timeout kills and reaps the child and its grandchild' {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'skip' } # tree-kill fallback needs Windows
    $sleeper = Join-Path $Scratch 'sleeper.ps1'; $pidFile = Join-Path $Scratch 'sleepers.txt'
    Set-Content $sleeper @"
`$p = Start-Process '$shell' -ArgumentList '-NoProfile -Command "Start-Sleep 60"' -PassThru
[IO.File]::WriteAllText('$pidFile', "`$PID``n`$(`$p.Id)")
Start-Sleep 60
"@
    $ids = @()
    try {
        # 12 s lets both shells start and record their ids even on a slow runner.
        & $agentLoop -Loop $loop2 -Role worker -Exe $shell -Arguments '-NoProfile', '-File', $sleeper -Once -AttemptTimeoutMinutes 0.2 | Out-Null
        $exitCode = $LASTEXITCODE; $ids = @(Get-Content $pidFile)
        # Killed, not necessarily reaped: an orphaned grandchild may linger as a zombie until init collects it.
        $alive = { param($id)
            if ($env:OS -eq 'Windows_NT') { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
            else { $state = "$(& ps -o stat= -p $id 2>$null)".Trim(); $state -and -not $state.StartsWith('Z') } }
        $deadline = [DateTime]::UtcNow.AddSeconds(10)   # unkilled sleepers live 60 s, so this cannot hide a miss
        while (@($ids | Where-Object { & $alive $_ }).Count -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        ($exitCode -eq 6) -and ($ids.Count -eq 2) -and -not @($ids | Where-Object { & $alive $_ }).Count
    } finally {
        foreach ($childId in $ids) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
    }
}
Check 'driver: full output is kept and a grandchild holding it open does not stall the driver' {
    if ($env:OS -eq 'Windows_NT') { return 'skip' }   # Windows hands the agent the files; Unix used pipes
    $pidFile = Join-Path $Scratch 'holder.txt'; $ids = @()
    $script = 'seq 1 100000; sleep 30 & echo $! > "$1"; echo END'
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        & $agentLoop -Loop $loop2 -Role worker -Exe '/bin/sh' -Arguments '-c', $script, 'sh', $pidFile -Once | Out-Null
        $exitCode = $LASTEXITCODE; $seconds = $timer.Elapsed.TotalSeconds; $ids = @(Get-Content $pidFile)
        $out = @(Get-Content (Join-Path $loop2 'WATCHERS/worker-last.txt'))
        ($exitCode -eq 6) -and ($seconds -lt 20) -and ($out.Count -eq 100001) -and ($out[-1] -eq 'END')
    } finally {
        foreach ($childId in $ids) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
    }
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
Check 'codex driver: default sandbox, caller config, and overridable TOML writable roots on worker resume' {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'skip' }   # drivers need PowerShell 7
    $taskName = if ($IsWindows) { "codex's task" } else { "codex's `"task`"" }
    $loop9 = Join-Path $Scratch "$taskName/.looper"; $record = Join-Path $Scratch 'codex-args.txt'
    & $shell -NoProfile -File $ps1Helper new $loop9 -Project $project | Out-Null
    if ($IsWindows) {
        $fake = Join-Path $Scratch 'fake-codex.cmd'
        Set-Content -LiteralPath $fake -Value "@echo %*>`"$record`""
    } else {
        $fake = Join-Path $Scratch 'fake-codex'
        Set-Content -LiteralPath $fake -Value "#!/bin/sh`nprintf '%s\n' `"`$@`" > '$($record.Replace("'", "'\''"))'"
        & chmod +x $fake
    }
    $driver = Join-Path $repo 'drivers/codex/run.ps1'
    $extra = '-c profile=credential-deny -c sandbox_workspace_write.writable_roots=[]'   # resume-safe -c only
    # JSON's quoted path is also a TOML basic string, including escaped Windows backslashes.
    $root = 'sandbox_workspace_write.writable_roots=[' + (ConvertTo-Json ([IO.Path]::GetFullPath($loop9)) -Compress) + ']'
    if ($IsWindows) { $root = '"' + $root.Replace('"', '\"') + '"' }   # .cmd echo records command-line quoting
    $ok = $true
    foreach ($session in 'fresh', 'resume') {
        foreach ($sandbox in 'default', 'config') {
            Set-Content -LiteralPath (Join-Path $loop9 'WATCHERS/worker.session') -Value '01234567-abcd'
            $options = @{}; if ($sandbox -eq 'config') { $options.Sandbox = 'config' }
            & $driver -Loop $loop9 -Role worker -Codex $fake -Session $session @options -Extra $extra -Once -MaxFailures 1 | Out-Null
            $exitCode = $LASTEXITCODE; $tokens = @(Get-Content -LiteralPath $record); $line = $tokens -join ' '
            $ok = $ok -and ($exitCode -eq 6) -and $line.EndsWith(' -') -and $line.Contains($extra)
            if ($sandbox -eq 'config') {
                $ok = $ok -and ($line -notmatch '--sandbox|sandbox_mode=|--add-dir') -and ([regex]::Matches($line, 'sandbox_workspace_write\.writable_roots=').Count -eq 1) -and
                    ((Get-Content -Raw (Join-Path $loop9 'WATCHERS/worker.log')) -match 'sandbox=config \(caller\)')
            } elseif ($session -eq 'fresh') {
                $ok = $ok -and ($line -match '^exec --sandbox workspace-write ')
            } else {
                $ok = $ok -and ($line -match '^exec resume ') -and $line.Contains('-c sandbox_mode=workspace-write') -and
                    $line.Contains("-c $root $extra")
            }
        }
    }
    $ok
}
Check 'driver: the agent gets its prompt on stdin; one that quits without reading it is only a failed attempt' {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return 'skip' }   # drivers need PowerShell 7
    $loop8 = Join-Path $Scratch 'stdin/.looper'
    & $shell -NoProfile -File $ps1Helper new $loop8 -Project (Join-Path $Scratch 'stdin') | Out-Null
    [IO.File]::WriteAllText((Join-Path $loop8 'EXCHANGE/HANDOFF.next.md'), "Request: review`nCandidate: stdin`n")
    & $shell -NoProfile -File $ps1Helper publish $loop8 handoff | Out-Null
    $got = Join-Path $Scratch 'stdin-got.txt'
    if ($IsWindows) {
        $reader = Join-Path $Scratch 'fake-reader.cmd'; $quitter = Join-Path $Scratch 'fake-quitter.cmd'
        Set-Content -LiteralPath $reader -Value "@`"$shell`" -NoProfile -Command `"[IO.File]::WriteAllText('$got', [Console]::In.ReadToEnd())`""
        Set-Content -LiteralPath $quitter -Value '@exit /b 3'
    } else {
        $reader = Join-Path $Scratch 'fake-reader'; $quitter = '/bin/true'   # exits at once: the likeliest to beat the prompt
        Set-Content -LiteralPath $reader -Value "#!/bin/sh`ncat > '$got'"
        & chmod +x $reader
    }
    $driver = Join-Path $repo 'drivers/claude-code/run.ps1'
    & $driver -Loop $loop8 -Claude $reader -Once -MaxFailures 1 *> $null
    $prompted = (Test-Path -LiteralPath $got) -and ((Get-Content -Raw -LiteralPath $got) -match 'Looper reviewer wake-up')
    # Before the fix, on Linux, a run like this threw "Broken pipe" now and then (1 in 40 in Docker,
    # 6 in 7 on another machine) instead of counting a failed attempt; timing decides, so repeat.
    $crashes = 0
    foreach ($i in 1..20) { try { & $driver -Loop $loop8 -Claude $quitter -Once -MaxFailures 1 *> $null } catch { $crashes++ } }
    $failedAttempts = @(Get-Content -LiteralPath (Join-Path $loop8 'WATCHERS/reviewer.log') | Where-Object { $_ -match 'attempt ended without publishing' }).Count
    $prompted -and ($crashes -eq 0) -and ($failedAttempts -ge 20)
}
Check 'final report bound by hash: done survives lost write times; an edit after the PASS is caught' {
    # The final handoff above was published after FINAL_REPORT.md was written, so it names its hash.
    $handoffText = [IO.File]::ReadAllText((Join-Path $loop 'EXCHANGE/HANDOFF.md'))
    $report = Join-Path $loop 'FINAL_REPORT.md'
    $named = $handoffText -match ('(?m)^Final report: `FINAL_REPORT\.md`, sha256 ' + (Sha $report) + '\s*$')
    # A git clone or a plain copy gives files arbitrary times: make the report look newer.
    [IO.File]::SetLastWriteTimeUtc($report, [DateTime]::UtcNow.AddHours(1))
    $doneAnyway = (Next) -eq 'done'
    $original = [IO.File]::ReadAllBytes($report)
    [IO.File]::AppendAllText($report, "`nEdited after the final PASS.`n")
    $status = Looper status $loop
    $caught = ((Next) -eq 'worker') -and ($status -match 'FINAL_REPORT.md changed after handoff')
    [IO.File]::WriteAllBytes($report, $original)
    $named -and $doneAnyway -and $caught -and ((Next) -eq 'done')
}
Check 'report hash after a UTF-8 BOM (as Windows PowerShell 5.1 writes): both editions read and publish it alike' {
    if (-not (Get-Command sh -ErrorAction SilentlyContinue)) { return 'skip' }   # needs both editions
    $shHelper = Join-Path $repo 'tools/looper.sh'
    function StatusBoth([string]$Folder) {
        $a = & $shell -NoProfile -File $ps1Helper status $Folder 2>&1 | Out-String
        $b = & sh $shHelper status $Folder 2>&1 | Out-String
        @([regex]::Match($a, '(?m)^NEXT: (\w+)').Groups[1].Value, [regex]::Match($b, '(?m)^NEXT: (\w+)').Groups[1].Value)
    }
    $bom = [string][char]0xFEFF; $utf8 = [Text.UTF8Encoding]::new($false)
    # A hand-written handoff whose first line is the binding, behind a BOM, with CRLF lines.
    $t = Join-Path $Scratch 'bom-status'; New-Item -ItemType Directory -Force -Path "$t/EXCHANGE", "$t/HISTORY" | Out-Null
    [IO.File]::WriteAllText("$t/FINAL_REPORT.md", "Original report`n", $utf8)
    $line = 'Final report: `FINAL_REPORT.md`, sha256 ' + (Sha "$t/FINAL_REPORT.md")
    [IO.File]::WriteAllText("$t/EXCHANGE/HANDOFF.md", "$bom$line`r`nRequest: final review`r`n", $utf8)
    Copy-Item "$t/EXCHANGE/HANDOFF.md" "$t/HISTORY/001_HANDOFF.md"
    [IO.File]::WriteAllText("$t/EXCHANGE/REVIEW.md", "Handoff: 001 $((Sha "$t/EXCHANGE/HANDOFF.md").Substring(0, 12))`nVerdict: PASS`n", $utf8)
    [IO.File]::SetLastWriteTimeUtc("$t/EXCHANGE/HANDOFF.md", [datetime]'2021-01-01')
    [IO.File]::SetLastWriteTimeUtc("$t/FINAL_REPORT.md", [datetime]'2030-01-01')   # newer, but unchanged
    $unchanged = StatusBoth $t
    [IO.File]::WriteAllText("$t/FINAL_REPORT.md", "Edited after the PASS`n", $utf8)
    [IO.File]::SetLastWriteTimeUtc("$t/FINAL_REPORT.md", [datetime]'2020-01-01')   # older, but changed
    $edited = StatusBoth $t
    # A BOM review whose first line is the verdict.
    [IO.File]::WriteAllText("$t/FINAL_REPORT.md", "Original report`n", $utf8)
    [IO.File]::WriteAllText("$t/EXCHANGE/REVIEW.md", "${bom}Verdict: PASS`nHandoff: 001 $((Sha "$t/EXCHANGE/HANDOFF.md").Substring(0, 12))`n", $utf8)
    $bomReview = StatusBoth $t
    # A trailing no-break space is not a space in either edition: the binding is not read, so write times decide.
    [IO.File]::WriteAllText("$t/FINAL_REPORT.md", "Edited after the PASS`n", $utf8)
    [IO.File]::WriteAllText("$t/EXCHANGE/HANDOFF.md", "$line$([char]0xA0)`nRequest: final review`n", $utf8)
    Copy-Item "$t/EXCHANGE/HANDOFF.md" "$t/HISTORY/001_HANDOFF.md" -Force
    [IO.File]::WriteAllText("$t/EXCHANGE/REVIEW.md", "Handoff: 001 $((Sha "$t/EXCHANGE/HANDOFF.md").Substring(0, 12))`nVerdict: PASS`n", $utf8)
    [IO.File]::SetLastWriteTimeUtc("$t/EXCHANGE/HANDOFF.md", [datetime]'2021-01-01')
    [IO.File]::SetLastWriteTimeUtc("$t/FINAL_REPORT.md", [datetime]'2020-01-01')
    $nbsp = StatusBoth $t
    # Publishing the same BOM draft (binding on its first line) with each edition.
    $ids = foreach ($e in 'ps1', 'sh') {
        $f = Join-Path $Scratch "bom-publish-$e/.looper"
        & $shell -NoProfile -File $ps1Helper new $f -Project (Join-Path $Scratch "bom-publish-$e") | Out-Null
        [IO.File]::WriteAllText("$f/FINAL_REPORT.md", "Report`n", $utf8)
        $l = 'Final report: `FINAL_REPORT.md`, sha256 ' + (Sha "$f/FINAL_REPORT.md")
        [IO.File]::WriteAllText("$f/EXCHANGE/HANDOFF.next.md", "$bom$l`r`nRequest: final review`r`n", $utf8)
        if ($e -eq 'ps1') { & $shell -NoProfile -File $ps1Helper publish $f handoff | Out-Null } else { & sh $shHelper publish $f handoff | Out-Null }
        $text = [IO.File]::ReadAllText("$f/EXCHANGE/HANDOFF.md").TrimStart([char]0xFEFF)
        '{0}:{1}' -f (Sha "$f/EXCHANGE/HANDOFF.md"), ([regex]::Matches($text, '(?m)^Final report: ').Count)
    }
    (($unchanged -join ',') -eq 'done,done') -and (($edited -join ',') -eq 'worker,worker') -and (($bomReview -join ',') -eq 'done,done') -and (($nbsp -join ',') -eq 'done,done') -and
    ($ids[0] -eq $ids[1]) -and ($ids[0] -like '*:1')
}
Check 'after done: re-sending an old handoff text cannot inherit its PASS' {
    # It now names the final report too, so it is a new request, never the old text.
    Draft HANDOFF "Request: review`nCandidate: value.txt = 2 (repaired)`n"
    $null = Looper publish $loop handoff
    $published = $code -eq 0
    Remove-Item (Join-Path $loop 'EXCHANGE/HANDOFF.next.md') -ErrorAction SilentlyContinue
    $published -and ((Next) -eq 'reviewer') -and ([IO.File]::ReadAllText((Join-Path $loop 'EXCHANGE/HANDOFF.md')) -match '(?m)^Final report: ')
}
# Lifecycle hygiene: reuse, clean, and driver sessions (fake agent, no model).
Check 'reuse: new on an existing task folder points to it instead of creating another' {
    $out = Looper new $loop
    ($code -ne 0) -and ($out -match 'already a Looper task')
}
$loop4 = Join-Path $Scratch 'sessions/.looper'
$null = Looper new $loop4 -Project (Join-Path $Scratch 'sessions')
$w4 = Join-Path $loop4 'WATCHERS'
Check 'clean: removes runtime files including hidden entries, keeps the record' {
    [IO.File]::WriteAllText((Join-Path $loop4 'EXCHANGE/HANDOFF.next.md'), "Request: review`nCandidate: s1`n")
    $null = Looper publish $loop4 handoff
    $junk = 'WATCHERS/reviewer.session', 'WATCHERS/reviewer-last.txt', 'EXCHANGE/REVIEW.next.md', 'EXCHANGE/.REVIEW.md.dead.tmp', 'HISTORY/.002_HANDOFF.md.dead.tmp', 'WATCHERS/.hidden', 'WATCHERS/..hidden', 'EXCHANGE/.hidden.next.md', 'EXCHANGE/.next.md', 'EXCHANGE/..hidden.next.md', 'EXCHANGE/UPPER.NEXT.MD', 'HISTORY/..hidden.TMP'
    [IO.File]::WriteAllText((Join-Path $w4 'reviewer.lock'), 'x')
    foreach ($j in $junk) { [IO.File]::WriteAllText((Join-Path $loop4 $j), 'x') }
    foreach ($dir in 'scratch', '.hidden-dir', '..hidden-dir', '.directory.log') {
        New-Item -ItemType Directory -Force -Path (Join-Path $w4 "$dir/probe") | Out-Null
        [IO.File]::WriteAllText((Join-Path $w4 "$dir/probe/copy.txt"), 'x')
    }
    foreach ($keep in '.hidden.log', '..hidden.LOG') { [IO.File]::WriteAllText((Join-Path $w4 $keep), 'log') }
    [IO.File]::WriteAllText((Join-Path $w4 'reviewer.log'), "log`n")
    $before = Looper status $loop4
    $out = Looper clean $loop4
    $left = @($junk | Where-Object { Test-Path (Join-Path $loop4 $_) })
    ($code -eq 0) -and ($left.Count -eq 0) -and -not @('scratch', '.hidden-dir', '..hidden-dir', '.directory.log' | Where-Object { Test-Path (Join-Path $w4 $_) }).Count -and
    (Test-Path (Join-Path $w4 '.hidden.log')) -and (Test-Path (Join-Path $w4 '..hidden.LOG')) -and (Test-Path (Join-Path $w4 'reviewer.log')) -and (Test-Path (Join-Path $w4 'README.md')) -and
    (Test-Path (Join-Path $w4 'reviewer.lock')) -and (Test-Path (Join-Path $loop4 'HISTORY/001_HANDOFF.md')) -and (Test-Path (Join-Path $loop4 'EXCHANGE/.publish.lock')) -and ((Looper status $loop4) -eq $before)
}
Check 'clean: holds both role locks and existing locks through deletion, then releases them' {
    $folder = Join-Path $Scratch 'clean-locks'
    $null = Looper new $folder -Project $project
    $watchers = Join-Path $folder 'WATCHERS'
    $probe = Join-Path $watchers '000-clean-probe.tmp'
    [IO.File]::WriteAllText($probe, 'x')
    foreach ($name in 'observer.lock', 'WORKER.lock') { [IO.File]::WriteAllText((Join-Path $watchers $name), '') }
    $bulk = Join-Path $watchers 'scratch'
    New-Item -ItemType Directory -Path $bulk | Out-Null
    [IO.File]::WriteAllText((Join-Path $bulk 'a.tmp'), '')
    $child = $null
    try {
        if ($helperKind -eq 'sh') {
            # A barrier, not timing: an rm first on PATH stops at the probe file until released, so
            # the locks are checked while deletion is in progress. looper.ps1 deletes in-process;
            # its hold-through-deletion is the same try/finally and is not paused here.
            $bin = Join-Path $Scratch 'rm-barrier'; $gate = Join-Path $Scratch 'rm-gate'
            New-Item -ItemType Directory -Path $bin | Out-Null
            $q = { param($s) "'" + $s.Replace("'", "'\''") + "'" }   # sh single-quoting
            $reached = & $q "$gate.reached"; $go = & $q "$gate.go"; $realRm = & $q (& sh -c 'command -v rm').Trim()
            [IO.File]::WriteAllText((Join-Path $bin 'rm'), @"
#!/bin/sh
for a; do case `$a in *000-clean-probe.tmp)
    : > $reached; i=0
    while [ ! -f $go ] && [ `$i -lt 300 ]; do sleep 0.1; i=`$((i + 1)); done ;;
esac; done
exec $realRm "`$@"
"@.Replace("`r", ''))
            # Put the barrier first from inside sh: Git for Windows' bin\sh.exe puts its own usr/bin first.
            [IO.File]::WriteAllText((Join-Path $bin 'first.sh'), "PATH=`$(cd -- `"`$(dirname -- `"`$0`")`" && pwd):`$PATH; export PATH; exec sh `"`$@`"`n")
            if ($env:OS -ne 'Windows_NT') { & chmod +x (Join-Path $bin 'rm') }
            $child = Start-TestProcess (Get-Command sh).Source @((Join-Path $bin 'first.sh'), $helperPath, 'clean', $folder)
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath "$gate.reached") -and -not $child.Process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            if (-not (Test-Path -LiteralPath "$gate.reached")) {
                if (-not $child.Process.HasExited) { $child.Process.Kill(); $null = $child.Process.WaitForExit(5000) }
                throw "clean never reached the probe: $(if ($child.Err.IsCompleted) { $child.Err.Result })"
            }
            foreach ($name in 'worker.lock', 'reviewer.lock', 'observer.lock', 'WORKER.lock') {
                try { $lease = [IO.File]::Open((Join-Path $watchers $name), 'OpenOrCreate', 'ReadWrite', 'None') }
                catch [IO.IOException] { continue }
                $lease.Dispose()
                throw "$name was available during deletion"
            }
            [IO.File]::WriteAllText("$gate.go", '')
        } else {
            $child = Start-TestProcess $shell @('-NoProfile', '-File', $helperPath, 'clean', $folder)
        }
        $null = Finish-Publish $child
        foreach ($name in 'worker.lock', 'reviewer.lock', 'observer.lock', 'WORKER.lock') {
            # Persistent inode, released only when cleanup has finished.
            $lease = [IO.File]::Open((Join-Path $watchers $name), 'Open', 'ReadWrite', 'None'); $lease.Dispose()
        }
        -not (Test-Path -LiteralPath $bulk) -and -not (Test-Path -LiteralPath $probe)
    } finally { Stop-TestProcess $child }
}
Check 'clean: refuses while a driver holds its lock, and deletes nothing' {
    # sh checks the Windows lock directly on Git Bash; Unix uses flock(1) or pwsh.
    [IO.File]::WriteAllText((Join-Path $w4 'reviewer.session'), 'x')
    New-Item -ItemType Directory -Force -Path (Join-Path $w4 'scratch') | Out-Null
    [IO.File]::WriteAllText((Join-Path $w4 'scratch/in-progress.txt'), 'x')
    $lock = [IO.File]::Open((Join-Path $w4 'reviewer.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { $null = Looper clean $loop4; $held = $code } finally { $lock.Dispose() }
    $kept = (Test-Path (Join-Path $w4 'reviewer.session')) -and (Test-Path (Join-Path $w4 'scratch/in-progress.txt'))
    $null = Looper clean $loop4   # released: cleans
    ($held -ne 0) -and $kept
}
if ($env:OS -ne 'Windows_NT') {
    Check 'clean: sh without flock uses pwsh to refuse a held lock, then cleans after release' {
        $bin = Join-Path $Scratch 'no-flock'
        New-Item -ItemType Directory -Path $bin | Out-Null
        foreach ($tool in 'sh', 'pwsh', 'perl', 'cat', 'mkdir', 'od', 'dirname', 'mktemp', 'uname', 'tr', 'rm', 'grep', 'paste', 'sed', 'basename', 'cp', 'sleep', 'cmp', 'sha256sum', 'cut', 'sort', 'awk', 'tail', 'mv', 'expr') {
            if ($tool -eq 'sha256sum' -and -not (Get-Command $tool -ErrorAction SilentlyContinue)) { $tool = 'shasum' }
            New-Item -ItemType SymbolicLink -Path (Join-Path $bin $tool) -Target (Get-Command $tool).Source | Out-Null
        }
        $lockPath = Join-Path $w4 'worker space '' $().lock'
        $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        $pathBefore = $env:PATH
        try {
            $env:PATH = $bin
            $out = & sh (Join-Path $repo 'tools/looper.sh') clean $loop4 2>&1
            $refused = ($LASTEXITCODE -ne 0) -and ("$out" -match 'is held') -and (Test-Path -LiteralPath $lockPath)
            $lock.Dispose()
            $null = & sh (Join-Path $repo 'tools/looper.sh') clean $loop4 2>&1
            $refused -and ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $lockPath)
        } finally { $env:PATH = $pathBefore; $lock.Dispose() }
    }
    if ($helperKind -eq 'sh') {
        Check 'publish: Perl fallback waits for a .NET holder, then publishes after release' {
            $taskFolder = Join-Path $Scratch 'held-perl/.looper'
            $null = Looper new $taskFolder
            $pathBefore = $env:PATH
            try { $env:PATH = Join-Path $Scratch 'no-flock'; Test-PublishExclusion $taskFolder }
            finally { $env:PATH = $pathBefore }
        }
        Check 'publish: a flock(1) without -E (old util-linux, macOS Homebrew, BusyBox) is not used; Perl serialises' {
            $taskFolder = Join-Path $Scratch 'held-other-flock/.looper'
            $null = Looper new $taskFolder
            $fake = Join-Path $Scratch 'other-flock'
            New-Item -ItemType Directory -Path $fake | Out-Null
            # Claims util-linux (2.21, before -E) but rejects -E: only an option probe catches it.
            [IO.File]::WriteAllText((Join-Path $fake 'flock'), "#!/bin/sh`n[ `"`$1`" = --version ] && { echo 'flock from util-linux 2.21'; exit 0; }`necho 'flock: invalid option -- E' >&2`nexit 64`n")
            & chmod +x (Join-Path $fake 'flock')
            $pathBefore = $env:PATH
            try { $env:PATH = $fake + ':' + (Join-Path $Scratch 'no-flock'); Test-PublishExclusion $taskFolder }
            finally { $env:PATH = $pathBefore }
        }
    }
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
Check 'skill build: expands literal tilde slash and backslash output paths before validation' {
    # The required folder-name guard reports the resolved path before any writes to the real home.
    $probe = 'looper-tilde-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $expected = Join-Path $HOME $probe
    foreach ($out in "~/$probe", "~\$probe") {
        $ErrorActionPreference = 'Continue'
        $message = & $shell -NoProfile -File (Join-Path $repo 'integrations/skill/build.ps1') -Out $out 2>&1
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0 -or "$message" -notmatch [regex]::Escape($expected)) { return $false }
    }
    $true
}
function Copy-Repo([string]$To) {
    foreach ($d in 'integrations/skill', 'template', 'prompts', 'tools', 'drivers', 'docs') {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent (Join-Path $To $d)) | Out-Null
        Copy-Item -Recurse -LiteralPath (Join-Path $repo $d) -Destination (Join-Path $To $d)
    }
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $To
    Join-Path $To 'integrations/skill/build.ps1'
}

Check 'skill build: replaces only a generated package, never the repository (even through a link)' {
    # Disposable copies, so a failed guard can only delete a copy. Every refused output is named
    # "looper", so only this guard (not the name rule) can refuse it.
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
Check 'skill build: provenance, hidden files and exact folder/zip manifests' {
    function Run-Build([string]$Script, [string[]]$BuildArgs) {
        $ErrorActionPreference = 'Continue'
        $message = & $shell -NoProfile -ExecutionPolicy Bypass -File $Script @BuildArgs 2>&1
        $ErrorActionPreference = 'Stop'
        [pscustomobject]@{ Code = $LASTEXITCODE; Message = "$message" }
    }
    $sourceBuild = Join-Path $repo 'integrations/skill/build.ps1'
    $installed = Join-Path $Scratch 'identity/looper'
    $result = Run-Build $sourceBuild @('-Out', $installed)
    if ($result.Code -ne 0) { throw $result.Message }
    $version = [IO.File]::ReadAllText((Join-Path $installed 'VERSION'))
    $lines = $version.TrimEnd().Split("`n") | ForEach-Object { $_.TrimEnd("`r") }
    if (($lines | ForEach-Object { ($_ -split ': ', 2)[0] }) -join ',' -cne 'generator,repository,commit,dirty,describe,date,git') { throw 'VERSION keys/order' }
    if ($gitOk -and (Test-Path -LiteralPath (Join-Path $repo '.git'))) {   # as the build: only this checkout's own .git
        $ErrorActionPreference = 'Continue'
        $head = & git -C $repo rev-parse --verify HEAD 2>$null
        $headCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($headCode -eq 0 -and ($version -cnotmatch '(?m)^commit: [0-9a-f]{40}\r?$' -or $lines[2] -cne "commit: $head")) { throw 'VERSION full commit' }
    }
    if ($version -notmatch '(?m)^repository: .+\r?$' -or $version -notmatch '(?m)^dirty: (true|false|unknown)\r?$' -or
        $version -notmatch '(?m)^describe: .+\r?$' -or $version -notmatch '(?m)^date: [0-9]{4}-[0-9]{2}-[0-9]{2}\r?$') { throw 'VERSION fields' }

    # Default builds in a disposable source copy exercise the zip without touching repo/dist.
    $build = Copy-Repo (Join-Path $Scratch 'manifest-source')
    $package = Join-Path $Scratch 'manifest-source/dist/looper'
    $zip = Join-Path $Scratch 'manifest-source/dist/looper-skill.zip'
    $result = Run-Build $build @()
    if ($result.Code -ne 0) { throw $result.Message }
    $result = Run-Build $build @('-Check')
    if ($result.Code -ne 0) { throw $result.Message }
    $files = @(Get-ChildItem -LiteralPath $package -Recurse -File -Force)
    if ($files.Count -ne 24 -or -not (Test-Path -LiteralPath (Join-Path $package 'template/HISTORY/.gitkeep'))) { throw 'expected 24 files including hidden .gitkeep' }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $paths = @($archive.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName })
        $expected = @($files | ForEach-Object { 'looper/' + $_.FullName.Substring($package.Length + 1).Replace('\', '/') })
        if ($paths.Count -ne 24 -or (($paths | Sort-Object) -join "`n") -cne (($expected | Sort-Object) -join "`n")) { throw 'folder/zip path mismatch' }
    } finally { $archive.Dispose() }
    $zipBytes = [IO.File]::ReadAllBytes($zip)
    foreach ($target in 'folder', 'zip') {
        foreach ($fault in 'missing', 'extra', 'changed', 'missing VERSION', 'invalid VERSION') {
            $rel = if ($fault -like '*VERSION') { 'VERSION' } elseif ($fault -eq 'extra') { 'template/HISTORY/.extra' } else { 'template/HISTORY/.gitkeep' }
            $path = Join-Path $package $rel
            $existed = Test-Path -LiteralPath $path
            if ($existed) { $saved = [IO.File]::ReadAllBytes($path) }
            try {
                if ($target -eq 'folder') {
                    if ($fault -like 'missing*') { Remove-Item -LiteralPath $path -Force }
                    else { [IO.File]::WriteAllText($path, 'tampered') }
                } else {
                    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
                    try {
                        $entry = $archive.GetEntry("looper/$rel")
                        if ($entry) { $entry.Delete() }
                        if ($fault -notlike 'missing*') {
                            $writer = [IO.StreamWriter]::new($archive.CreateEntry("looper/$rel").Open())
                            try { $writer.Write('tampered') } finally { $writer.Dispose() }
                        }
                    } finally { $archive.Dispose() }
                }
                $result = Run-Build $build @('-Check')
                if ($result.Code -eq 0) { throw "-Check accepted $target with $fault file" }
            } finally {
                if ($target -eq 'zip') { [IO.File]::WriteAllBytes($zip, $zipBytes) }
                elseif ($existed) { [IO.File]::WriteAllBytes($path, $saved) }
                else { Remove-Item -LiteralPath $path -Force }
            }
        }
    }
    $result = Run-Build $build @('-Check')
    if ($result.Code -ne 0) { throw $result.Message }
    # The default zip is replaced only when it is a generated package: rebuilding over its own zip works,
    # an unrelated file of that name is refused before anything changes.
    $result = Run-Build $build @()
    if ($result.Code -ne 0) { throw "rebuild over its own zip: $($result.Message)" }
    [IO.File]::WriteAllText($zip, 'not a package')
    $result = Run-Build $build @()
    if ($result.Code -eq 0 -or [IO.File]::ReadAllText($zip) -cne 'not a package') { throw 'replaced an unrelated looper-skill.zip' }
    Remove-Item -LiteralPath $zip -Force
    # A source export nested in another repository records no provenance, and the date is Gregorian in any culture.
    if ($gitOk) {
        $parent = Join-Path $Scratch 'nest-parent'
        $ErrorActionPreference = 'Continue'
        & git init -q $parent 2>$null; & git -C $parent config remote.origin.url https://example.invalid/parent.git 2>$null
        $ErrorActionPreference = 'Stop'
        $build = Copy-Repo (Join-Path $parent 'export')
        $out = Join-Path $Scratch 'nest-out/looper'
        $command = "[Threading.Thread]::CurrentThread.CurrentCulture = 'th-TH'; & '$build' -Out '$out'; exit `$LASTEXITCODE"
        $ErrorActionPreference = 'Continue'
        $message = & $shell -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -ne 0) { throw "$message" }
        $version = [IO.File]::ReadAllText((Join-Path $out 'VERSION'))
        if ($version -cnotmatch '(?m)^repository: unknown\r?$' -or $version -cnotmatch '(?m)^commit: unknown\r?$') { throw 'nested export took the parent provenance' }
        if ($version -cnotmatch '(?m)^date: (?<y>[0-9]{4})-' -or [int]$Matches.y -gt (Get-Date).ToUniversalTime().AddDays(1).Year) { throw 'VERSION date is not Gregorian' }
    }
    $true
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
Check 'lifecycle: Once final PASS exits 0 and removes session, last-output files and scratch' {
    [IO.File]::WriteAllText((Join-Path $loop4 'FINAL_REPORT.md'), "# FINAL REPORT`ndone`n")
    Start-Sleep -Milliseconds 50
    Publish-Handoff4 "Request: final review`nCandidate: s4 + report`n"
    New-Item -ItemType Directory -Path (Join-Path $w4 'scratch') -Force | Out-Null
    $code2 = Invoke-FakeDriver
    ($code2 -eq 0) -and -not (Test-Path $sessionFile4) -and -not (Test-Path (Join-Path $w4 'reviewer-last.txt')) -and
    -not (Test-Path (Join-Path $w4 'reviewer-last.err')) -and -not (Test-Path (Join-Path $w4 'scratch')) -and
    ([regex]::Match((Looper status $loop4), '(?m)^NEXT: (\w+)').Groups[1].Value -eq 'done') -and ((Invoke-FakeDriver) -eq 0)
}
# Codex adapter, Windows only: re-owning sandbox-created files must never lose or change state.
$reown = Join-Path $repo 'drivers/codex/reown.ps1'
function Get-Temps { @(Get-ChildItem -LiteralPath $loop -Recurse -Force -Filter '*.tmp' | ForEach-Object FullName) -join ',' }
function Get-Snapshot {
    Get-ChildItem -LiteralPath $loop -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]WATCHERS[\\/]' } |
        ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.FullName, (Sha $_.FullName), $_.LastWriteTimeUtc.Ticks, $_.CreationTimeUtc.Ticks }
}
Check 'codex re-own: files re-created with identical content and times; HISTORY untouched; status unchanged' {
    if (($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) -or -not (Get-Command Get-Acl -ErrorAction SilentlyContinue)) { return 'skip' }
    $statusBefore = Looper status $loop
    $tempsBefore = Get-Temps
    $before = @(Get-Snapshot)
    $hold = [IO.File]::Open((Join-Path $loop 'EXCHANGE/.publish.lock'), 'Open', 'ReadWrite', 'None')
    try { $out = & $reown -Folder $loop -OwnerPattern '.' } finally { $hold.Dispose() }
    $after = @(Get-Snapshot)
    $strip = { param($s) ($s | ForEach-Object { ($_ -split '\|')[0..2] -join '|' }) -join "`n" }
    $histBefore = @($before | Where-Object { $_ -match '[\\/]HISTORY[\\/]' }) -join "`n"
    $histAfter = @($after | Where-Object { $_ -match '[\\/]HISTORY[\\/]' }) -join "`n"
    ((& $strip $before) -eq (& $strip $after)) -and ($histBefore -eq $histAfter) -and ($out -match 're-created') -and
    ((Looper status $loop) -eq $statusBefore) -and ((Get-Temps) -eq $tempsBefore) -and ("$out" -notmatch '\.publish\.lock')
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
