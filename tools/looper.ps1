#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Looper L1 helper: plain file operations for a local worker/reviewer loop.

.DESCRIPTION
  looper.ps1 new     <loop> [-Task <name>] [-Project <dir>]   create a task instance from template/
  looper.ps1 status  <loop>                                   show whose move it is (never changes anything)
  looper.ps1 publish <loop> handoff|review [-Draft <file>]    archive to HISTORY and publish atomically
  looper.ps1 wait    <loop> -For worker|reviewer              block until that role has due work
  looper.ps1 clean   <loop>                                   delete disposable runtime files (keeps the record)

  The helper never calls a model, never edits source and never judges work. Everything it
  decides is derived from the files, so any agent can also follow the same rules by hand
  (see docs/contract.md).

  Due rule: a HANDOFF is settled only by a REVIEW (the answer) that names that handoff's content hash.
  Until such a review is published, the handoff stays due, whatever happened to the reviewer.

  wait exit codes: 0 = due, 2 = loop done, 3 = timed out with nothing due (just wait again).
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)][ValidateSet('new', 'status', 'publish', 'wait', 'clean', 'help')][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Loop = '.looper',
    [Parameter(Position = 2)][ValidateSet('handoff', 'review')][string]$Kind,
    [string]$Task,
    [string]$Project,
    [string]$Draft,
    [ValidateSet('worker', 'reviewer')][string]$For,
    [ValidateRange(0.01, 10080)][double]$TimeoutMinutes = 720,
    [ValidateRange(1, 3600)][int]$PollSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Marker = '<!-- looper:template -->'
$LooperHome = Split-Path -Parent $PSScriptRoot

function Stop-Looper([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("LOOPER ERROR: $Message")
    exit $Code
}

function Get-Sha([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-Shared([string]$Path) {
    # Full sharing, so a publisher's rename over this file is never blocked by a reader.
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try { $buffer = [IO.MemoryStream]::new(); $stream.CopyTo($buffer); return , $buffer.ToArray() }
    finally { $stream.Dispose() }
}

function Read-Stable([string]$Path) {
    # Bytes only once two reads agree; $null when missing, empty or still being written.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            if (-not [IO.File]::Exists($Path)) { return $null }
            $first = Read-Shared $Path
            Start-Sleep -Milliseconds 150
            $second = Read-Shared $Path
            if ($second.Length -eq 0) { return $null }
            if ((Get-Sha $first) -ceq (Get-Sha $second)) { return , $second }
        } catch [IO.IOException] { } catch [UnauthorizedAccessException] { }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function New-Note([byte[]]$Bytes) {
    $sha = Get-Sha $Bytes
    [pscustomobject]@{
        Bytes = $Bytes
        Text  = [Text.Encoding]::UTF8.GetString($Bytes).TrimStart([char]0xFEFF)
        Sha   = $sha
        Short = $sha.Substring(0, 12)
    }
}

function Get-Note([string]$Path) {
    # A published exchange file, or $null when absent, unstable or still the unfilled template.
    $bytes = Read-Stable $Path
    if ($null -eq $bytes) { return $null }
    $note = New-Note $bytes
    if ($note.Text.Contains($Marker)) { return $null }
    return $note
}

function Get-Paths([string]$Root) {
    [pscustomobject]@{
        Root     = $Root
        Handoff  = Join-Path $Root 'EXCHANGE/HANDOFF.md'
        Review   = Join-Path $Root 'EXCHANGE/REVIEW.md'
        Final    = Join-Path $Root 'FINAL_REPORT.md'
        History  = Join-Path $Root 'HISTORY'
        Exchange = Join-Path $Root 'EXCHANGE'
    }
}

function Get-HistoryHandoffs($P) {
    # Published handoffs in order: number, sha. HISTORY is the complete exchange log.
    if (-not [IO.Directory]::Exists($P.History)) { return @() }
    @(Get-ChildItem -LiteralPath $P.History -File | Where-Object Name -Match '^(\d+)_HANDOFF\.md$' |
        Sort-Object { [int]($_.Name -replace '_.*$', '') } | ForEach-Object {
            [pscustomobject]@{ Number = [int]($_.Name -replace '_.*$', ''); Sha = Get-Sha ([IO.File]::ReadAllBytes($_.FullName)) }
        })
}

function Get-Verdict([string]$Text) {
    # Soft format: "Verdict: PASS", "**Verdict:** repair", or a Verdict heading with the word below it.
    $m = [regex]::Match($Text, '(?im)^[\s>*_#-]*verdict[\s*_]*[:=-]?[\s*_`]*(PASS|REPAIR|BLOCKED)\b')
    if (-not $m.Success) {
        $m = [regex]::Match($Text, '(?im)^[\s>*_#-]*verdict[\s*_:]*\r?\n(?:[ \t]*\r?\n)*[\s>*_#`-]*(PASS|REPAIR|BLOCKED)\b')
    }
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return ''
}

function Get-Binding([string]$Text, $Known) {
    # Hard identity: which published handoff does this review name? A line whose label mentions
    # "handoff" (but not previous/prior/earlier/old/last) and carries a 12-64 hex hash prefix.
    $found = @()
    foreach ($line in ($Text -split '\r?\n')) {
        $colon = $line.IndexOf(':')
        if ($colon -lt 0) { continue }
        $label = $line.Substring(0, $colon)
        if ($label -notmatch '(?i)\bhandoff\b' -or $label -match '(?i)\b(previous|prior|earlier|old|last)\b') { continue }
        foreach ($token in [regex]::Matches($line.Substring($colon + 1), '\b[0-9a-fA-F]{12,64}\b')) {
            $prefix = $token.Value.ToLowerInvariant()
            $found += @($Known | Where-Object { $_.Sha.StartsWith($prefix) })
        }
    }
    $distinct = @($found | Sort-Object Sha -Unique)
    if ($distinct.Count -eq 1) { return $distinct[0] }
    if ($distinct.Count -gt 1) { return 'ambiguous' }
    return $null
}

function Get-State([string]$Root) {
    $P = Get-Paths $Root
    $handoff = Get-Note $P.Handoff
    $review = Get-Note $P.Review
    $final = Get-Note $P.Final
    $known = Get-HistoryHandoffs $P
    $state = [ordered]@{ Handoff = $handoff; HandoffNumber = ''; Review = $review; Verdict = ''; ReviewFor = $null; Final = $final; Next = ''; Why = '' }

    if ($handoff) {
        $match = @($known | Where-Object Sha -ceq $handoff.Sha | Select-Object -Last 1)
        $state.HandoffNumber = if ($match) { '{0:000}' -f $match[0].Number } else { '???' }
        if (-not ($known | Where-Object Sha -ceq $handoff.Sha)) { $known += [pscustomobject]@{ Number = 0; Sha = $handoff.Sha } }
    }
    if ($review) {
        $state.Verdict = Get-Verdict $review.Text
        $binding = Get-Binding $review.Text $known
        if ($binding -and $binding -isnot [string]) { $state.ReviewFor = $binding }
    }

    if (-not $handoff) {
        $state.Next = 'worker'; $state.Why = 'no handoff published yet'
    } elseif (-not $state.ReviewFor -or $state.ReviewFor.Sha -cne $handoff.Sha) {
        $state.Next = 'reviewer'; $state.Why = "handoff $($state.HandoffNumber) $($handoff.Short) has no applicable review"
    } elseif ($state.Verdict -eq 'PASS' -and $final -and
        [IO.File]::GetLastWriteTimeUtc($P.Final) -le [IO.File]::GetLastWriteTimeUtc($P.Handoff)) {
        # Done only when the report existed before the handoff that passed, i.e. it was reviewed.
        # A report written after the last PASS (or just before the final handoff) is not done yet.
        $state.Next = 'done'; $state.Why = "handoff $($state.HandoffNumber) passed and FINAL_REPORT.md is written"
    } else {
        $state.Next = 'worker'; $state.Why = "answer ($(if ($state.Verdict) { $state.Verdict } else { 'no verdict' })) published for handoff $($state.HandoffNumber) $($handoff.Short)"
    }
    return [pscustomobject]$state
}

function Write-Atomic([string]$Path, [byte[]]$Bytes) {
    # Temp file in the same folder, then rename over the target: readers see old or new, never half.
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    for ($attempt = 1; ; $attempt++) {
        try {
            # [NullString]: a plain $null would reach .NET as "" (no backup file wanted).
            if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch [IO.IOException] {
            # A reader, sync client or virus scanner can hold the target for a moment.
            if ($attempt -ge 20) { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds 100
        } catch {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            throw
        }
    }
}

function Resolve-Loop([string]$Path) {
    [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Path))
}

function Publish-Pair([string]$HistoryPath, [string]$Target, [byte[]]$Bytes) {
    # History first, then the current file. If the current file cannot be replaced (for example a
    # sandbox that may create but not overwrite), undo the new history copy: nothing is published.
    $existed = [IO.File]::Exists($HistoryPath)
    Write-Atomic $HistoryPath $Bytes
    try { Write-Atomic $Target $Bytes }
    catch {
        if (-not $existed) { Remove-Item -LiteralPath $HistoryPath -Force -ErrorAction SilentlyContinue }
        Stop-Looper "could not replace $Target ($($_.Exception.Message)); nothing was published. Keep the draft and retry once the file is writable."
    }
}

function Assert-Loop([string]$Root) {
    if (-not [IO.Directory]::Exists((Join-Path $Root 'EXCHANGE'))) {
        Stop-Looper "$Root is not a Looper task folder (no EXCHANGE/). Create one with: looper.ps1 new <folder>"
    }
}

function Invoke-New([string]$Root) {
    if ([IO.Directory]::Exists($Root) -and @(Get-ChildItem -LiteralPath $Root -Force).Count -gt 0) {
        if ([IO.File]::Exists((Join-Path $Root 'CONTEXT.md')) -and [IO.Directory]::Exists((Join-Path $Root 'EXCHANGE'))) {
            Stop-Looper "$Root is already a Looper task. Continue it (read its CONTEXT.md) instead of creating another; for a different task use another folder, or pack/remove this one first."
        }
        Stop-Looper "$Root already exists and is not empty; Looper never overwrites a folder."
    }
    $projectDir = if ($Project) { Resolve-Loop $Project } else { (Get-Location).ProviderPath }
    $taskName = if ($Task) { $Task } else { Split-Path -Leaf $projectDir }
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    Copy-Item -Path (Join-Path $LooperHome 'template/*') -Destination $Root -Recurse -Force
    Get-ChildItem -LiteralPath $Root -Recurse -Force -Filter '.gitkeep' | Remove-Item -Force
    $helper = Join-Path $LooperHome 'tools/looper.ps1'
    $context = Join-Path $Root 'CONTEXT.md'
    $text = [IO.File]::ReadAllText($context)
    $fill = @{ TASK = $taskName; LOOP = $Root; PROJECT = $projectDir; LOOPER_HOME = $LooperHome; HELPER = $helper; CREATED = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    foreach ($key in $fill.Keys) { $text = $text.Replace('{{' + $key + '}}', $fill[$key]) }
    [IO.File]::WriteAllText($context, $text, [Text.UTF8Encoding]::new($false))

    # Keep the task folder out of the project's commits without touching tracked files.
    $git = $null
    try { $ErrorActionPreference = 'Continue'; $git = & git -C $projectDir rev-parse --show-toplevel 2>$null; $gitDir = & git -C $projectDir rev-parse --absolute-git-dir 2>$null }
    catch { $git = $null } finally { $ErrorActionPreference = 'Stop' }
    if ($git -and $gitDir) {
        $top = [IO.Path]::GetFullPath($git).TrimEnd('\', '/')
        if ($Root.StartsWith($top + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $Root.Substring($top.Length + 1).Replace('\', '/')
            $exclude = Join-Path $gitDir 'info/exclude'
            [IO.Directory]::CreateDirectory((Split-Path -Parent $exclude)) | Out-Null
            $lines = if ([IO.File]::Exists($exclude)) { [IO.File]::ReadAllLines($exclude) } else { @() }
            if ("/$relative/" -notin $lines) { [IO.File]::AppendAllText($exclude, "`n/$relative/`n") }
        }
    }

    Write-Output "LOOPER created $Root"
    Write-Output ''
    Write-Output 'Worker next: fill PLAN.md and TASK.md (proportionately), then start work.'
    Write-Output 'Give this one-line prompt to an independent reviewer, once:'
    Write-Output ''
    Write-Output "  You are the REVIEWER for the Looper task at $Root. Read $context and follow the reviewer route."
}

function Show-Status([string]$Root) {
    $s = Get-State $Root
    Write-Output "LOOPER $Root"
    Write-Output ('handoff: ' + $(if ($s.Handoff) { "$($s.HandoffNumber) $($s.Handoff.Short)" } else { 'none' }))
    $reviewLine = if (-not $s.Review) { 'none' }
    elseif ($s.ReviewFor) { $n = if ($s.ReviewFor.Number) { '{0:000}' -f $s.ReviewFor.Number } else { '???' }; "$(if ($s.Verdict) { $s.Verdict } else { 'ANSWER' }) for handoff $n $($s.ReviewFor.Sha.Substring(0, 12))" }
    else { "$(if ($s.Verdict) { $s.Verdict } else { 'ANSWER' }) (names no published handoff)" }
    Write-Output "review:  $reviewLine"
    Write-Output ('final:   ' + $(if ($s.Final) { 'written' } else { 'not written' }))
    Write-Output "NEXT: $($s.Next) - $($s.Why)"
}

function Invoke-Publish([string]$Root) {
    if (-not $Kind) { Stop-Looper 'publish needs a kind: handoff or review' }
    $P = Get-Paths $Root
    $name = $Kind.ToUpperInvariant()
    $target = Join-Path $P.Exchange "$name.md"
    $defaultDraft = Join-Path $P.Exchange "$name.next.md"
    $draftPath = if ($Draft) { Resolve-Loop $Draft } else { $defaultDraft }
    if (-not [IO.File]::Exists($draftPath)) { Stop-Looper "no draft at $draftPath. Write the $Kind there first." }
    $bytes = [IO.File]::ReadAllBytes($draftPath)
    if ($bytes.Length -eq 0) { Stop-Looper "draft $draftPath is empty." }
    $note = New-Note $bytes
    if ($note.Text.Contains($Marker)) { Stop-Looper "draft still contains the template marker $Marker - write the real $Kind." }
    $known = Get-HistoryHandoffs $P

    if ($Kind -eq 'handoff') {
        $current = Get-Note $P.Handoff
        if ($current -and $current.Sha -ceq $note.Sha) {
            if ($draftPath -eq $defaultDraft) { Remove-Item -LiteralPath $draftPath -Force }
            Write-Output "LOOPER unchanged: handoff $($note.Short) is already published; nothing to do."
            return
        }
        $last = @($known | Select-Object -Last 1)
        $earlier = @($known | Where-Object { $_.Sha -ceq $note.Sha -and $_.Number -ne $last[0].Number } | Select-Object -First 1)
        if ($earlier) {
            # Identity is the text's hash, so identical text would inherit that handoff's old answer.
            Stop-Looper ('this exact handoff text was already published as {0:000}. A re-sent request must differ (e.g. say why it is sent again) so an old answer cannot settle it.' -f $earlier[0].Number)
        }
        $number = if ($last -and $last[0].Sha -ceq $note.Sha) { $last[0].Number } else { 1 + [int]($known | ForEach-Object Number | Measure-Object -Maximum).Maximum }
        Publish-Pair (Join-Path $P.History ('{0:000}_HANDOFF.md' -f $number)) $target $bytes
        if ($draftPath -eq $defaultDraft) { Remove-Item -LiteralPath $draftPath -Force }
        Write-Output ('LOOPER published handoff {0:000} {1} - NEXT: reviewer' -f $number, $note.Short)
        return
    }

    # Only identity is required. A verdict is for review requests; other answers may omit it.
    $verdict = Get-Verdict $note.Text
    if (-not $verdict) { $verdict = 'answer' }
    $current = Get-Note $P.Handoff
    if (-not $current) { Stop-Looper 'there is no published handoff to review.' }
    if (-not ($known | Where-Object Sha -ceq $current.Sha)) { $known += [pscustomobject]@{ Number = 0; Sha = $current.Sha } }
    $binding = Get-Binding $note.Text $known
    $currentNumber = @($known | Where-Object Sha -ceq $current.Sha | Select-Object -Last 1)[0].Number
    $hint = "Handoff: {0:000} {1}" -f $currentNumber, $current.Short
    if ($null -eq $binding) { Stop-Looper "review must name the handoff it reviewed, e.g. '$hint'." }
    if ($binding -is [string]) { Stop-Looper "review names more than one handoff; keep one 'Handoff:' line, e.g. '$hint'." }
    if ($binding.Sha -cne $current.Sha) {
        Stop-Looper ("stale review: it names handoff {0:000} {1} but the current handoff is {2}. Not published; review the current handoff." -f $binding.Number, $binding.Sha.Substring(0, 12), $hint) 4
    }
    $base = '{0:000}_REVIEW' -f $binding.Number
    $historyPath = Join-Path $P.History "$base.md"
    for ($i = 2; [IO.File]::Exists($historyPath) -and (Get-Sha ([IO.File]::ReadAllBytes($historyPath))) -cne $note.Sha; $i++) {
        $historyPath = Join-Path $P.History "${base}_$i.md"
    }
    Publish-Pair $historyPath $target $bytes
    if ($draftPath -eq $defaultDraft) { Remove-Item -LiteralPath $draftPath -Force }
    Write-Output ('LOOPER published review {0} for handoff {1:000} {2} - NEXT: worker' -f $verdict, $binding.Number, $current.Short)
}

function Invoke-Clean([string]$Root) {
    # Durable record: CONTEXT, PLAN, TASK, EXCHANGE/HANDOFF.md + REVIEW.md, HISTORY/, FINAL_REPORT,
    # WATCHERS/README.md and WATCHERS/*.log. Everything else below is disposable runtime state.
    $P = Get-Paths $Root
    $watchers = Join-Path $Root 'WATCHERS'
    foreach ($lock in @(Get-ChildItem -LiteralPath $watchers -Filter '*.lock' -File -ErrorAction SilentlyContinue)) {
        try { ([IO.File]::Open($lock.FullName, 'Open', 'ReadWrite', 'None')).Dispose() }
        catch [IO.IOException] { Stop-Looper "a driver is running ($($lock.Name) is held); stop it before cleaning." }
    }
    $junk = @(Get-ChildItem -LiteralPath $watchers -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' -and $_.Extension -ne '.log' })
    $junk += @(Get-ChildItem -LiteralPath $P.Exchange -File -Force | Where-Object { $_.Name -like '*.next.md' -or $_.Name -like '.*.tmp' })
    $junk += @(Get-ChildItem -LiteralPath $P.History -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.*.tmp' })
    $junk += @(Get-ChildItem -LiteralPath $watchers -Directory -Force -ErrorAction SilentlyContinue)   # e.g. scratch/
    $junk | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
    Write-Output "LOOPER cleaned $($junk.Count) runtime file(s): $(($junk | ForEach-Object Name) -join ', ')"
    Write-Output 'Kept: CONTEXT, PLAN, TASK, EXCHANGE/HANDOFF.md, EXCHANGE/REVIEW.md, HISTORY/, FINAL_REPORT, WATCHERS/README.md and logs.'
}

function Invoke-Wait([string]$Root) {
    if (-not $For) { Stop-Looper 'wait needs -For worker or -For reviewer' }
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $watcher = [IO.FileSystemWatcher]::new($Root)
    $watcher.IncludeSubdirectories = $true
    $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'
    $watcher.EnableRaisingEvents = $true
    try {
        while ($true) {
            # Scan before every wait: events are only hints, the files are the truth.
            $s = Get-State $Root
            if ($s.Next -eq 'done') { Write-Output "LOOPER DONE - $($s.Why)"; exit 2 }
            if ($s.Next -eq $For) { Write-Output "LOOPER DUE $For - $($s.Why)"; exit 0 }
            $left = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($left -le 0) { Write-Output "LOOPER WAIT TIMEOUT - nothing due for $For after $TimeoutMinutes min; wait again"; exit 3 }
            $null = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, [int][Math]::Min($left, $PollSeconds * 1000))
        }
    } finally { $watcher.Dispose() }
}

if ($Command -eq 'help') { Get-Help $PSCommandPath -Detailed | Out-String | Write-Output; exit 0 }
$root = Resolve-Loop $Loop
if ($Command -eq 'new') { Invoke-New $root; exit 0 }
Assert-Loop $root
switch ($Command) {
    'status' { Show-Status $root }
    'publish' { Invoke-Publish $root }
    'wait' { Invoke-Wait $root }
    'clean' { Invoke-Clean $root }
}
