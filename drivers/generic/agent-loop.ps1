#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Generic Looper driver: wake a CLI agent whenever its role has due work.

.DESCRIPTION
  Loop: wait until <Role> is due -> run the agent once with a tiny prompt on stdin -> re-read the
  files. If the attempt published nothing (crash, timeout, lost runner), the work simply stays due
  and is retried after -RetrySeconds, up to -MaxFailures consecutive failures. Exits when the task
  is done. It never judges work or edits anything except its own WATCHERS/<role>.* files.

  Sessions (runtime state only; deleting them never loses the task):
    -Session fresh   every attempt is a new session that cold-starts from the task folder.
    -Session resume  continue the session saved in WATCHERS/<role>.session. If the runtime says
                     that session is unavailable (-ResumeFailurePattern), cold-start a fresh one
                     in the same attempt. An attempt that simply publishes nothing keeps its session.

  Placeholders in -Arguments / -ResumeArguments: {LOOP} task folder, {PROJECT} project dir from
  CONTEXT.md, {HOME} Looper home, {SESSION} (resume only). Provider wrappers build them.

  Exit codes: 0 task done; 4 another driver already holds this role's lock; 5 gave up after
  -MaxFailures attempts that published nothing (work is still due; fix the cause and rerun).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Loop,
    [Parameter(Mandatory)][ValidateSet('worker', 'reviewer')][string]$Role,
    [Parameter(Mandatory)][string]$Exe,
    [string[]]$Arguments = @(),
    [string[]]$ResumeArguments = @(),
    [ValidateSet('fresh', 'resume')][string]$Session = 'fresh',
    # First group = the provider's session id, found in the child's output.
    [string]$SessionPattern,
    # Output that means "this session cannot be resumed" (e.g. not found) - triggers a cold start.
    [string]$ResumeFailurePattern,
    # What was asked for, e.g. 'model=gpt-6.1-sol effort=high' - logged as requested, not as fact.
    [string]$Requested,
    # 'name=regex' pairs whose first group is what the runtime itself reports, e.g. 'model=^model: (\S+)'.
    [string[]]$Report = @(),
    # Command a person can run to open or continue the session, e.g. 'codex resume {SESSION}'.
    [string]$AttachHint,
    # Provider-specific preparation run before each attempt with the task folder path
    # (e.g. file-permission repair for a sandbox). Must not change any file's content.
    [scriptblock]$BeforeAttempt,
    [ValidateSet('LOOP', 'PROJECT')][string]$WorkingDirectory = 'LOOP',
    [ValidateRange(1, 1440)][int]$AttemptTimeoutMinutes = 60,
    [ValidateRange(1, 100)][int]$MaxFailures = 3,
    [ValidateRange(0, 86400)][int]$RetrySeconds = 60,
    [ValidateRange(1, 10080)][int]$WaitMinutes = 60,
    [switch]$Show,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LooperHome = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$helper = Join-Path $LooperHome 'tools/looper.ps1'
$Loop = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Loop))
$watchers = Join-Path $Loop 'WATCHERS'
$log = Join-Path $watchers "$Role.log"
$sessionFile = Join-Path $watchers "$Role.session"
$outFile = Join-Path $watchers "$Role-last.txt"
$errFile = Join-Path $watchers "$Role-last.err"

function Write-Log([string]$Message) {
    $line = '{0} {1} {2}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'), $Role, $Message
    [IO.File]::AppendAllText($log, $line + [Environment]::NewLine)
    Write-Output $line
}

function Get-Next {
    $text = (& $helper status $Loop) -join "`n"
    $m = [regex]::Match($text, '(?m)^NEXT: (\w+)')
    $h = [regex]::Match($text, '(?m)^handoff: (.*)$').Groups[1].Value
    [pscustomobject]@{ Next = $m.Groups[1].Value; Handoff = $h; Text = $text }
}

function Format-Argument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Expand([string[]]$List, [string]$Id) {
    @($List | ForEach-Object { $_.Replace('{LOOP}', $Loop).Replace('{PROJECT}', $project).Replace('{HOME}', $LooperHome).Replace('{SESSION}', $Id) })
}

function Read-Output { [string]((Get-Content -Raw -LiteralPath $outFile -ErrorAction SilentlyContinue) + (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)) }

function Show-New([hashtable]$Seen) {
    # -Show: echo what the child has written since last time, so a person can watch it work.
    foreach ($file in $outFile, $errFile) {
        if (-not [IO.File]::Exists($file)) { continue }
        $stream = [IO.FileStream]::new($file, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            if ($stream.Length -le $Seen[$file]) { continue }
            $null = $stream.Seek($Seen[$file], 'Begin')
            $reader = [IO.StreamReader]::new($stream)
            [Console]::Out.Write($reader.ReadToEnd())
            $Seen[$file] = $stream.Length
        } finally { $stream.Dispose() }
    }
}

function Invoke-Child([string[]]$ArgList) {
    # One run of the agent CLI; returns its exit code (or 'killed'). Output goes to WATCHERS files.
    $proc = Start-Process -FilePath $Exe -ArgumentList (($ArgList | ForEach-Object { Format-Argument $_ }) -join ' ') `
        -WorkingDirectory $cwd -RedirectStandardInput $promptFile -RedirectStandardOutput $outFile `
        -RedirectStandardError $errFile -NoNewWindow -PassThru
    $null = $proc.Handle   # keeps ExitCode readable on Windows PowerShell 5.1
    $deadline = [DateTime]::UtcNow.AddMinutes($AttemptTimeoutMinutes)
    $seen = @{ $outFile = 0L; $errFile = 0L }
    while (-not $proc.WaitForExit(1000)) {
        if ($Show) { Show-New $seen }
        if ([DateTime]::UtcNow -gt $deadline) {
            if ($PSVersionTable.PSVersion.Major -ge 7) { $proc.Kill($true) } else { & taskkill.exe /T /F /PID $proc.Id | Out-Null }
            Write-Log "attempt killed after $AttemptTimeoutMinutes min"
            return 'killed'
        }
    }
    if ($Show) { Show-New $seen }
    try { $proc.ExitCode } catch { 'unknown' }
}

if (-not (Test-Path -LiteralPath (Join-Path $Loop 'CONTEXT.md'))) { throw "$Loop is not a Looper task folder." }
$project = [regex]::Match([IO.File]::ReadAllText((Join-Path $Loop 'CONTEXT.md')), '(?m)^- Project / source: `([^`]+)`').Groups[1].Value
if (-not $project) { $project = $Loop }
$cwd = if ($WorkingDirectory -eq 'PROJECT') { $project } else { $Loop }
if ($Session -eq 'resume' -and -not ($ResumeArguments -and $SessionPattern)) { throw "-Session resume is not supported by this driver (no resume command)." }

# One driver per role per task: an exclusive handle the OS releases however this process ends.
try { $lease = [IO.File]::Open((Join-Path $watchers "$Role.lock"), 'OpenOrCreate', 'ReadWrite', 'None') }
catch [IO.IOException] { Write-Output "LOOPER DRIVER already running for $Role in $Loop"; exit 4 }

$prompt = "Looper $Role wake-up. Task folder: $Loop`nRead $(Join-Path $Loop 'CONTEXT.md') and follow the $Role route: do the work that is due and publish it with the Looper helper. If nothing is due for you, stop."
$promptFile = Join-Path $watchers ".$Role-prompt.txt"
[IO.File]::WriteAllText($promptFile, $prompt, [Text.UTF8Encoding]::new($false))
$failures = 0
try {
    Write-Log "driver started: $Exe (pid $PID) session=$Session$(if ($Requested) { " requested: $Requested" })"
    while ($true) {
        & $helper wait $Loop -For $Role -TimeoutMinutes $WaitMinutes | Out-Null
        if ($LASTEXITCODE -eq 2) {
            # Completed run: drop this role's disposable runtime files (the log stays as the record).
            Remove-Item -LiteralPath $sessionFile, $outFile, $errFile -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $watchers 'scratch') -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log 'task done; driver exiting'
            exit 0
        }
        if ($LASTEXITCODE -eq 3) { continue }
        if ($LASTEXITCODE -ne 0) { throw "looper wait failed with exit code $LASTEXITCODE" }

        $before = Get-Next
        $saved = if ($Session -eq 'resume' -and [IO.File]::Exists($sessionFile)) { ([IO.File]::ReadAllText($sessionFile)).Trim() } else { '' }
        $mode = if ($saved) { "resume $saved" } else { 'fresh' }
        Write-Log "attempt start ($mode) - handoff $($before.Handoff)"
        if ($BeforeAttempt) { $note = & $BeforeAttempt $Loop; if ($note) { Write-Log "before attempt: $note" } }
        $code = if ($saved) { Invoke-Child (Expand $ResumeArguments $saved) } else { Invoke-Child (Expand $Arguments '') }
        if ($saved -and $code -ne 0 -and $ResumeFailurePattern -and (Read-Output) -match $ResumeFailurePattern) {
            # Explicit "cannot resume" from the runtime: nothing was published, so cold-start now.
            Write-Log "resume unavailable ($saved): $($Matches[0]); cold start"
            Remove-Item -LiteralPath $sessionFile -ErrorAction SilentlyContinue
            $code = Invoke-Child (Expand $Arguments '')
        }

        $text = Read-Output
        $id = if ($SessionPattern) { $m = [regex]::Match($text, $SessionPattern); if ($m.Success) { $m.Groups[1].Value } else { '' } } else { '' }
        if ($id -and $Session -eq 'resume') { [IO.File]::WriteAllText($sessionFile, $id) }
        $reported = @($Report | ForEach-Object {
            $name, $pattern = $_ -split '=', 2
            $found = @([regex]::Matches($text, $pattern) | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
            "$name=$(if ($found) { $found -join ',' } else { '(not reported)' })"
        }) -join ' '
        $details = "exit $code$(if ($id) { ", session $id" })$(if ($reported) { ", runtime reported: $reported" })"

        $after = Get-Next
        if ($after.Next -ne $Role -or $after.Handoff -ne $before.Handoff) {
            $failures = 0
            Write-Log "attempt published ($details) - NEXT: $($after.Next)"
        } else {
            $failures++
            Write-Log "attempt ended without publishing ($details); work stays due ($failures/$MaxFailures)"
            if ($failures -ge $MaxFailures) { Write-Log 'giving up; rerun the driver after fixing the cause (or try -Session fresh)'; exit 5 }
        }
        if ($id -and $AttachHint) { Write-Output "  open this session: $($AttachHint.Replace('{SESSION}', $id))" }
        if ($Once) { exit 0 }
        if ($failures -gt 0) { Start-Sleep -Seconds $RetrySeconds }
    }
} finally {
    Remove-Item -LiteralPath $promptFile -ErrorAction SilentlyContinue
    $lease.Dispose()
}
