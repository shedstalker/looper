#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Looper L1 helper: plain file operations for a local worker/reviewer loop.

.DESCRIPTION
  looper.ps1 new     <loop> [-Task <name>] [-Project <dir>]   create a task instance from template/
  looper.ps1 status  <loop>                                   show whose move it is (never changes anything)
  looper.ps1 publish <loop> handoff|review [-Draft <file>]    archive to HISTORY and publish atomically
             handoff only: [-Attach <file>,...]                snapshot files into HISTORY, list size + SHA-256
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
    [string[]]$Attach,
    [ValidateSet('worker', 'reviewer')][string]$For,
    # One number syntax in both helpers: decimal minutes, whole seconds; ranges are checked below.
    [ValidatePattern('\A[0-9]+([.][0-9]+)?\z')][string]$TimeoutMinutes = '720',
    [ValidatePattern('\A[0-9]+\z')][string]$PollSeconds = '30'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Marker = '<!-- looper:template -->'
$script:AttachDir = $null   # a publish's attachment snapshot folder, removed again if the publish fails
$LooperHome = Split-Path -Parent $PSScriptRoot
$pathComparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Stop-Looper([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("LOOPER ERROR: $Message")
    exit $Code
}
$waitMinutes = [double]::Parse($TimeoutMinutes, [Globalization.CultureInfo]::InvariantCulture)
$pollSec = [double]::Parse($PollSeconds, [Globalization.CultureInfo]::InvariantCulture)
if ($waitMinutes -lt 0.01 -or $waitMinutes -gt 10080 -or $pollSec -lt 1 -or $pollSec -gt 3600) {
    Stop-Looper 'TimeoutMinutes must be 0.01..10080; PollSeconds must be a whole number 1..3600.'
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
    # Bytes and write time, only once two reads agree and the file was not replaced in between;
    # $null when missing, empty or still being written. The time travels with the bytes, so the
    # done rule never pairs an old file's content with a newer file's time (a publish can replace
    # the file between a read and a separate time lookup).
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            if (-not [IO.File]::Exists($Path)) { return $null }
            $before = [IO.File]::GetLastWriteTimeUtc($Path)
            $first = Read-Shared $Path
            Start-Sleep -Milliseconds 150
            $second = Read-Shared $Path
            $after = [IO.File]::GetLastWriteTimeUtc($Path)
            if ($second.Length -eq 0) { return $null }
            if ($before -eq $after -and (Get-Sha $first) -ceq (Get-Sha $second)) { return [pscustomobject]@{ Bytes = $second; Time = $after } }
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
    $read = Read-Stable $Path
    if ($null -eq $read) { return $null }
    $note = New-Note $read.Bytes
    if ($note.Text.Contains($Marker)) { return $null }
    $note | Add-Member Time $read.Time
    return $note
}

function Get-ReportSha([string]$Text) {
    # The final report a handoff names (publish adds the line when the report is written), or $null.
    $m = [regex]::Matches($Text, '(?m)^Final report: `FINAL_REPORT\.md`, sha256 ([0-9a-f]{64})[ \t\r\n\f\v]*$')   # ASCII spaces, as looper.sh
    if ($m.Count) { $m[$m.Count - 1].Groups[1].Value } else { $null }
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
    @(Get-ChildItem -LiteralPath $P.History -File | Where-Object Name -CMatch '^([0-9]+)_HANDOFF\.md$' |
        Sort-Object { [int]($_.Name -replace '_.*$', '') } | ForEach-Object {
            [pscustomobject]@{ Number = [int]($_.Name -replace '_.*$', ''); Sha = Get-Sha ([IO.File]::ReadAllBytes($_.FullName)) }
        })
}

function Get-Verdict([string]$Text) {
    # Soft format: "Verdict: PASS", "**Verdict:** repair", or a Verdict heading with the word below it.
    # One ASCII grammar, as in looper.sh: fold only A-Z, then match exactly.
    $Text = [regex]::Replace($Text, '[A-Z]+', { param($m) $m.Value.ToLowerInvariant() })
    $s = ' \t\r\n\f\v'; $end = '(pass|repair|blocked)(?![a-z0-9_])'
    $m = [regex]::Match($Text, '(?m)^[' + $s + '>*_#-]*verdict[' + $s + '*_]*[-:=]?[' + $s + '*_`]*' + $end)
    if (-not $m.Success) {
        $m = [regex]::Match($Text, '(?m)^[' + $s + '>*_#-]*verdict[' + $s + '*_:]*\r?\n(?:[ \t]*\r?\n)*[' + $s + '>*_#`-]*' + $end)
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
        # The verdict's ASCII grammar, as looper.sh: fold only A-Z; words end at anything but [a-z0-9_].
        $label = [regex]::Replace($line.Substring(0, $colon), '[A-Z]+', { param($m) $m.Value.ToLowerInvariant() })
        if ($label -cnotmatch '(?<![a-z0-9_])handoff(?![a-z0-9_])' -or $label -cmatch '(?<![a-z0-9_])(previous|prior|earlier|old|last)(?![a-z0-9_])') { continue }
        foreach ($token in [regex]::Matches($line.Substring($colon + 1), '(?<![A-Za-z0-9_])[0-9a-fA-F]{12,64}(?![A-Za-z0-9_])')) {
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
        # A handoff written by hand may be missing from HISTORY; an answer naming it must still bind.
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
    } elseif ($state.Verdict -eq 'PASS' -and $final -and $(
            # Done only when the passing handoff covered this exact report, i.e. it was reviewed. The
            # handoff names the report's hash; older or hand-written ones fall back to write times.
            $named = Get-ReportSha $handoff.Text
            if ($named) { $final.Sha -ceq $named } else { $final.Time -le $handoff.Time })) {
        $state.Next = 'done'; $state.Why = "handoff $($state.HandoffNumber) passed and FINAL_REPORT.md is written"
    } elseif ($state.Verdict -eq 'PASS' -and $final -and (Get-ReportSha $handoff.Text)) {
        $state.Next = 'worker'; $state.Why = "FINAL_REPORT.md changed after handoff $($state.HandoffNumber) named it; publish a new final handoff"
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
    try { Write-Atomic $HistoryPath $Bytes }
    catch {
        if ($script:AttachDir) { Remove-Item -LiteralPath $script:AttachDir -Recurse -Force -ErrorAction SilentlyContinue }
        Stop-Looper "could not write $HistoryPath ($($_.Exception.Message)); nothing was published. Keep the draft and retry once the file is writable."
    }
    try { Write-Atomic $Target $Bytes }
    catch {
        if (-not $existed) { Remove-Item -LiteralPath $HistoryPath -Force -ErrorAction SilentlyContinue }
        if ($script:AttachDir) { Remove-Item -LiteralPath $script:AttachDir -Recurse -Force -ErrorAction SilentlyContinue }
        Stop-Looper "could not replace $Target ($($_.Exception.Message)); nothing was published. Keep the draft and retry once the file is writable."
    }
}

function Assert-Loop([string]$Root) {
    if (-not [IO.Directory]::Exists((Join-Path $Root 'EXCHANGE'))) {
        Stop-Looper "$Root is not a Looper task folder (no EXCHANGE/). Create one with: looper.ps1 new <folder>"
    }
}

function Get-GitLine([string]$Dir, [string]$Arguments) {
    # git's one-line answer in $Dir, or $null (no git, not a repository). Read as UTF-8, which git
    # prints: `& git` would decode with the console code page (OEM on Windows) and corrupt non-ASCII.
    try {
        $psi = [Diagnostics.ProcessStartInfo]::new('git', $Arguments)
        $psi.WorkingDirectory = $Dir; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $p = [Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEndAsync(); $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit(); $null = $err.Result
        if ($p.ExitCode -eq 0) { $out.TrimEnd("`r", "`n") } else { $null }
    } catch { $null }
}

function Invoke-New([string]$Root) {
    if ([IO.Directory]::Exists($Root) -and @(Get-ChildItem -LiteralPath $Root -Force).Count -gt 0) {
        if ([IO.File]::Exists((Join-Path $Root 'CONTEXT.md')) -and [IO.Directory]::Exists((Join-Path $Root 'EXCHANGE'))) {
            Stop-Looper "$Root is already a Looper task. Continue it (read its CONTEXT.md) instead of creating another; for a different task use another folder, or pack/remove this one first."
        }
        Stop-Looper "$Root already exists and is not empty; Looper never overwrites a folder."
    }
    $projectDir = if ($Project) { Resolve-Loop $Project } else { (Get-Location).ProviderPath }
    if (-not [IO.Directory]::Exists($projectDir)) { Stop-Looper "no project folder $projectDir; nothing was created." }
    $taskName = if ($Task) { $Task } else { Split-Path -Leaf $projectDir }
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    Copy-Item -Path (Join-Path $LooperHome 'template/*') -Destination $Root -Recurse -Force
    Get-ChildItem -LiteralPath $Root -Recurse -Force -Filter '.gitkeep' | Remove-Item -Force
    $context = Join-Path $Root 'CONTEXT.md'
    $text = [IO.File]::ReadAllText($context)
    $fill = [ordered]@{ TASK = $taskName; LOOP = $Root; PROJECT = $projectDir; LOOPER_HOME = $LooperHome; CREATED = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    foreach ($key in $fill.Keys) { $text = $text.Replace('{{' + $key + '}}', $fill[$key]) }
    [IO.File]::WriteAllText($context, $text, [Text.UTF8Encoding]::new($false))

    # Keep the task folder out of the project's commits without touching tracked files.
    # Ask git for the folder's path inside its repo, as looper.sh does: comparing path spellings
    # fails where the temp or home path is a symlink (macOS /var -> /private/var) or C:/ vs /c/.
    # --git-path: the exclude file git reads (in a linked worktree, the main repository's).
    $prefix = Get-GitLine $Root 'rev-parse --show-prefix'
    $excludePath = Get-GitLine $Root 'rev-parse --git-path info/exclude'
    if ($prefix -and $excludePath) {
        $exclude = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $excludePath))   # may be relative to the folder
        [IO.Directory]::CreateDirectory((Split-Path -Parent $exclude)) | Out-Null
        $lines = if ([IO.File]::Exists($exclude)) { [IO.File]::ReadAllLines($exclude) } else { @() }
        $entry = '/' + ($prefix -replace '([\\\[\]*?])', '\$1' -replace ' $', '\ ')
        if ($entry -cnotin $lines) { [IO.File]::AppendAllText($exclude, "`n$entry`n") }
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
    # The publish lock makes these leftovers safe to remove after an interrupted publish.
    Get-ChildItem -LiteralPath $P.History -File -Force -Filter '.*.tmp' |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    $name = $Kind.ToUpperInvariant()
    $target = Join-Path $P.Exchange "$name.md"
    $defaultDraft = Join-Path $P.Exchange "$name.next.md"
    $draftPath = if ($Draft) { Resolve-Loop $Draft } else { $defaultDraft }
    # Only the default draft is removed after publishing. Ordinal, so a name differing only in case
    # (a distinct file on Linux or in a case-sensitive Windows folder) is never taken for it.
    $isDefaultDraft = [string]::Equals($draftPath, $defaultDraft, [StringComparison]::Ordinal)
    if (-not $isDefaultDraft -and [IO.Path]::DirectorySeparatorChar -eq '/' -and -not $draftPath.Contains('\') -and
        [string]::Equals([IO.Path]::GetFileName($draftPath), "$name.next.md", [StringComparison]::Ordinal)) {
        # The same folder by another spelling (macOS /var is /private/var): compare physical folders, as looper.sh does.
        # Ordinal: -ceq is linguistic, so distinct Unicode-equal Linux folders would compare equal.
        $physical = foreach ($d in @([IO.Path]::GetDirectoryName($draftPath), $P.Exchange)) {
            Push-Location -LiteralPath $d -ErrorAction SilentlyContinue
            if ($?) { "$(& /bin/sh -c 'pwd -P')"; Pop-Location } else { '' }
        }
        $isDefaultDraft = $physical[1] -and [string]::Equals($physical[0], $physical[1], [StringComparison]::Ordinal)
    }
    if (-not [IO.File]::Exists($draftPath)) { Stop-Looper "no draft at $draftPath. Write the $Kind there first." }
    $bytes = [IO.File]::ReadAllBytes($draftPath)
    if ($bytes.Length -eq 0) { Stop-Looper "draft $draftPath is empty." }
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255))) {
        Stop-Looper "draft $draftPath is UTF-16; save it as UTF-8. Nothing was published."
    }
    $note = New-Note $bytes
    if ($note.Text.Contains($Marker)) { Stop-Looper "draft still contains the template marker $Marker - write the real $Kind." }
    $known = Get-HistoryHandoffs $P
    if ($Attach -and $Kind -ne 'handoff') { Stop-Looper '-Attach is for handoffs only.' }

    $snapshots = @()
    if ($Attach) {
        # Files outside Git (a document, an export): each is read once; those bytes are both hashed
        # and snapshotted into HISTORY, and the list becomes part of the handoff text, so the id
        # changes whenever a file does and the reviewer reads an immutable local copy.
        $lines = foreach ($item in $Attach) {
            # -File cannot pass arrays, so a comma list may arrive as one string. (Windows PowerShell
            # throws on a joined string with two drive letters rather than calling it no file.)
            $single = try { [IO.File]::Exists((Resolve-Loop $item)) } catch { $false }
            $paths = if ($single) { , $item } else { $item -split ',' }
            foreach ($path in $paths) {
                $full = Resolve-Loop $path   # literal: a space is part of a name
                if (-not [IO.File]::Exists($full)) { Stop-Looper "attachment not found (files only): $full" }
                $name = [IO.Path]::GetFileName($full)   # .NET, so a backslash on Unix stays in the name
                if ($snapshots | Where-Object { [string]::Equals($_.Name, $name, $pathComparison) }) { Stop-Looper "two attachments are named $name; rename one." }
                $data = [IO.File]::ReadAllBytes($full)
                $snapshots += [pscustomobject]@{ Name = $name; Bytes = $data }
                '- `{0}`: {1} bytes, sha256 {2}' -f $name, $data.Length, (Get-Sha $data)
            }
        }
        # The text names no number, so re-sending the same text and files stays one quiet handoff.
        $gap = if ($bytes[-1] -eq 10) { "`n" } else { "`n`n" }
        $block = "${gap}Attachments (snapshots in ``HISTORY/<number>_attachments/``, <number> being this handoff's; review those, not the originals):`n" + ($lines -join "`n") + "`n"
        $bytes = [byte[]]($bytes + [Text.Encoding]::UTF8.GetBytes($block))
        $note = New-Note $bytes
    }

    if ($Kind -eq 'handoff') {
        # A written final report is bound by content: its hash becomes part of the handoff, so "done"
        # never depends on write times (git clones and plain copies do not keep them).
        $report = Get-Note $P.Final
        if ($report -and -not (Get-ReportSha $note.Text)) {
            $gap = if ($bytes[-1] -eq 10) { "`n" } else { "`n`n" }
            $bytes = [byte[]]($bytes + [Text.Encoding]::UTF8.GetBytes("${gap}Final report: ``FINAL_REPORT.md``, sha256 $($report.Sha)`n"))
            $note = New-Note $bytes
        }
        $current = Get-Note $P.Handoff
        if ($current -and $current.Sha -ceq $note.Sha) {
            if ($isDefaultDraft) { Remove-Item -LiteralPath $draftPath -Force }
            Write-Output "LOOPER unchanged: handoff $($note.Short) is already published; nothing to do."
            return
        }
        $last = @($known | Select-Object -Last 1)
        $earlier = @($known | Where-Object { $_.Sha -ceq $note.Sha -and $_.Number -ne $last[0].Number } | Select-Object -First 1)
        if ($earlier) {
            # Identity is the text's hash, so identical text would inherit that handoff's old answer.
            Stop-Looper ('this exact handoff text was already published as {0:000}. A re-sent request must differ (e.g. say why it is sent again) so an old answer cannot settle it.' -f $earlier[0].Number)
        }
        $restoring = $last -and $last[0].Sha -ceq $note.Sha
        $number = if ($restoring) { $last[0].Number } else { 1 + [int]($known | ForEach-Object Number | Measure-Object -Maximum).Maximum }
        $historyHandoff = Join-Path $P.History ('{0:000}_HANDOFF.md' -f $number)
        if ([IO.Directory]::Exists($historyHandoff) -or ([IO.File]::Exists($historyHandoff) -and
                (Get-Sha ([IO.File]::ReadAllBytes($historyHandoff))) -cne $note.Sha)) {
            # HISTORY is append-only: an existing file is only ever rewritten with its own bytes (a restore). The file
            # system may equate a name the scan reads differently (001_HANDOFF.MD on Windows or macOS) with this one:
            # never overwrite it, nor take its snapshot for an orphan.
            Stop-Looper "$historyHandoff already exists with other content; rename or remove it. Nothing was published."
        }
        if ($snapshots) {
            $dir = Join-Path $P.History ('{0:000}_attachments' -f $number)
            if ([IO.Directory]::Exists($dir) -and -not @($known | Where-Object Number -eq $number).Count) {
                # No recorded handoff (by number, as HISTORY is read) owns this snapshot: an interrupted publish left it behind.
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
            if ([IO.Directory]::Exists($dir) -or [IO.File]::Exists($dir)) {
                # Restoring the latest handoff (its EXCHANGE copy was lost): reuse its snapshot, but
                # only if it holds exactly these files, byte for byte. Never touch it otherwise.
                $same = $restoring -and [IO.Directory]::Exists($dir) -and
                    (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq $snapshots.Count) -and
                    -not @($snapshots | Where-Object {
                            $f = [IO.Path]::Combine($dir, $_.Name)
                            -not [IO.File]::Exists($f) -or (Get-Sha ([IO.File]::ReadAllBytes($f))) -cne (Get-Sha $_.Bytes) })
                if (-not $same) { Stop-Looper "$dir already exists and does not match these attachments; nothing was published." }
            } else {
                $script:AttachDir = $dir   # created here, so removed again if anything below fails
                try {
                    $null = New-Item -ItemType Directory -Path $dir
                    foreach ($s in $snapshots) { [IO.File]::WriteAllBytes([IO.Path]::Combine($dir, $s.Name), $s.Bytes) }
                } catch {
                    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                    Stop-Looper "could not write the attachment snapshot $dir ($($_.Exception.Message)); nothing was published."
                }
            }
        }
        Publish-Pair $historyHandoff $target $bytes
        if ($isDefaultDraft) { Remove-Item -LiteralPath $draftPath -Force }
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
    if ($isDefaultDraft) { Remove-Item -LiteralPath $draftPath -Force }
    $s = Get-State $Root  # recompute NEXT: a PASS on the final handoff makes the task done
    Write-Output ('LOOPER published review {0} for handoff {1:000} {2} - NEXT: {3}' -f $verdict, $binding.Number, $current.Short, $s.Next)
}

function Invoke-Clean([string]$Root) {
    # Durable record: CONTEXT, PLAN, TASK, EXCHANGE/HANDOFF.md + REVIEW.md, HISTORY/, FINAL_REPORT,
    # WATCHERS/README.md, *.lock and *.log. Everything else below is disposable runtime state.
    $P = Get-Paths $Root
    $watchers = Join-Path $Root 'WATCHERS'
    [IO.Directory]::CreateDirectory($watchers) | Out-Null
    $leases = @()
    try {
        # Create both role locks first, so a first-time driver cannot start during deletion; then
        # list and hold every lock (one entry per file, also on a case-insensitive volume).
        foreach ($role in 'worker', 'reviewer') {
            try { ([IO.File]::Open((Join-Path $watchers "$role.lock"), 'OpenOrCreate', 'ReadWrite', 'ReadWrite')).Dispose() }
            catch [IO.IOException] { Stop-Looper "a driver is running ($role.lock is held); stop it before cleaning." }
        }
        $locks = @(Get-ChildItem -LiteralPath $watchers -Filter '*.lock' -File -Force | ForEach-Object FullName)
        foreach ($lock in $locks) {
            try { $leases += [IO.File]::Open($lock, 'OpenOrCreate', 'ReadWrite', 'None') }
            catch [IO.IOException] { Stop-Looper "a driver is running ($([IO.Path]::GetFileName($lock)) is held); stop it before cleaning." }
        }
        $junk = @(Get-ChildItem -LiteralPath $watchers -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' -and $_.Extension -notin '.log', '.lock' })
        $junk += @(Get-ChildItem -LiteralPath $P.Exchange -File -Force | Where-Object { $_.Name -like '*.next.md' -or $_.Name -like '.*.tmp' })
        $junk += @(Get-ChildItem -LiteralPath $P.History -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.*.tmp' })
        $junk += @(Get-ChildItem -LiteralPath $watchers -Directory -Force -ErrorAction SilentlyContinue)   # e.g. scratch/
        $junk | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
    } finally { foreach ($lease in $leases) { $lease.Dispose() } }
    Write-Output "LOOPER cleaned $($junk.Count) runtime file(s): $(($junk | ForEach-Object Name) -join ', ')"
    Write-Output 'Kept: CONTEXT, PLAN, TASK, EXCHANGE/HANDOFF.md, EXCHANGE/REVIEW.md, HISTORY/, FINAL_REPORT, WATCHERS/README.md, driver locks and logs.'
}

function Invoke-Wait([string]$Root) {
    if (-not $For) { Stop-Looper 'wait needs -For worker or -For reviewer' }
    $For = $For.ToLowerInvariant()   # report the role as looper.sh does
    $deadline = [DateTime]::UtcNow.AddMinutes($waitMinutes)
    $watcher = $null
    # Queue events for the whole wait: WaitForChanged hears only changes during the call, so a
    # publish that landed during a scan went unnoticed until the next poll. Own tag: the helper may
    # run in-process in an agent's session, whose other events are not ours to wait on or drop.
    $tag = 'looper-wait-' + [guid]::NewGuid().ToString('N')
    try {
        try {
            $watcher = [IO.FileSystemWatcher]::new($Root)
            $watcher.IncludeSubdirectories = $true
            $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'
            foreach ($name in 'Created', 'Changed', 'Deleted', 'Renamed') { $null = Register-ObjectEvent $watcher $name -SourceIdentifier "$tag.$name" }
            $watcher.EnableRaisingEvents = $true
        } catch {
            Unregister-Event -SourceIdentifier "$tag.*" -ErrorAction SilentlyContinue
            if ($watcher) { $watcher.Dispose(); $watcher = $null }
        }
        while ($true) {
            # Scan before every wait: events are only hints, the files are the truth. Events so far
            # are covered by this scan; a later one stays queued and ends the next wait at once.
            Get-Event -SourceIdentifier "$tag.*" -ErrorAction SilentlyContinue | Remove-Event
            $s = Get-State $Root
            if ($s.Next -eq 'done') { Write-Output "LOOPER DONE - $($s.Why)"; exit 2 }
            if ($s.Next -eq $For) { Write-Output "LOOPER DUE $For - $($s.Why)"; exit 0 }
            $left = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($left -le 0) { Write-Output "LOOPER WAIT TIMEOUT - nothing due for $For after $TimeoutMinutes min; wait again"; exit 3 }
            $delay = [int][Math]::Ceiling([Math]::Min($left, $pollSec * 1000) / 1000)
            if ($watcher) { $null = Wait-Event -SourceIdentifier "$tag.*" -Timeout $delay }
            else { Start-Sleep -Seconds $delay }
        }
    } finally {
        Unregister-Event -SourceIdentifier "$tag.*" -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier "$tag.*" -ErrorAction SilentlyContinue | Remove-Event
        if ($watcher) { $watcher.Dispose() }
    }
}

if ($Command -eq 'help') { Get-Help $PSCommandPath -Detailed | Out-String | Write-Output; exit 0 }
$root = Resolve-Loop $Loop
if ([IO.Path]::DirectorySeparatorChar -eq '/' -and $root.Contains('\')) {
    # PowerShell path cmdlets read a backslash as a separator here, so they would address another folder.
    Stop-Looper "task path $root has a backslash, which looper.ps1 cannot use on this OS; use looper.sh or rename the folder."
}
if ($Command -eq 'new') { Invoke-New $root; exit 0 }
Assert-Loop $root
$publishLock = $null
try {
    if ($Command -in 'publish', 'clean') {
        # Persistent file; Unix uses flock(2), Windows share-none excludes Perl's open too.
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while ($null -eq $publishLock) {
            try { $publishLock = [IO.File]::Open((Join-Path $root 'EXCHANGE/.publish.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch [IO.IOException] {
                if ($deadline.Elapsed.TotalSeconds -ge 90) { Stop-Looper 'timed out waiting 90 s for the publish lock; nothing was published.' }
                Start-Sleep -Milliseconds 200
            }
        }
    }
    switch ($Command) {
    'status' { Show-Status $root }
    'publish' { Invoke-Publish $root }
    'wait' { Invoke-Wait $root }
    'clean' { Invoke-Clean $root }
    }
} finally {
    if ($null -ne $publishLock) { $publishLock.Dispose() }
}
