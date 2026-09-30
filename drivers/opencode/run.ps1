#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run a Looper role with OpenCode headless (`opencode run`), one run per due item.

.EXAMPLE
  pwsh -File drivers/opencode/run.ps1 -Loop C:\work\app\.looper -Model xai/grok-4.7            # reviewer
  pwsh -File drivers/opencode/run.ps1 -Loop C:\work\app\.looper -Model ollama/qwen36-64k -Show
  pwsh -File drivers/opencode/run.ps1 -Loop C:\work\app\.looper -Model xai/grok-4.7 -Role worker

  The model is OpenCode's choice: any `provider/model` it lists (`opencode models`), signed in
  through OpenCode (`opencode providers login`). Looper logs it as requested only - OpenCode's
  output does not say which model answered.
  Reviewer: working folder = the task folder (the only place it may edit); it reads the project.
  Worker:   working folder = the project; it may edit anything except the reviewer's files.
  Guardrails (OPENCODE_PERMISSION, merged over your OpenCode config): both may run commands;
  outside paths are refused except the project, the task folder and the Looper home; web tools
  and subagents are refused. These are rules, not a sandbox: a role that can run commands can do
  what your account can. -Permission own uses your OpenCode config unchanged.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Loop,
    [ValidateSet('reviewer', 'worker')][string]$Role = 'reviewer',
    [string]$Model,
    [string]$Variant,
    [ValidateSet('fresh', 'resume')][string]$Session = 'resume',
    [ValidateSet('looper', 'own')][string]$Permission = 'looper',
    [string]$OpenCode,
    [string]$Extra = '',
    [int]$AttemptTimeoutMinutes = 60,
    [int]$MaxFailures = 3,
    [switch]$Show,
    [switch]$Once
)
$ErrorActionPreference = 'Stop'

if (-not $OpenCode) {
    $OpenCode = (Get-Command opencode -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $OpenCode) { throw 'opencode CLI not found; pass -OpenCode <path>.' }
}
$Loop = [IO.Path]::GetFullPath($Loop)
$home_ = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$context = [IO.File]::ReadAllText((Join-Path $Loop 'CONTEXT.md'))
$project = [regex]::Match($context, '(?m)^- Project / source: `([^`]+)`').Groups[1].Value
$taskHome = [regex]::Match($context, '(?m)^- Looper home: `([^`]+)`').Groups[1].Value   # the copy the prompts point to
if (-not $project) { $project = $Loop }
if (-not (Test-Path -LiteralPath $project -PathType Container)) {
    throw "CONTEXT.md names the project '$project', which this PowerShell cannot find (a task created by the sh helper under Git Bash records POSIX paths). Create the task with tools/looper.ps1, or correct the Project line."
}

$callerPermission = $env:OPENCODE_PERMISSION   # restored below: running in-process must not leak
try {
if ($Permission -eq 'looper') {
    # OpenCode matches edit rules against the file path relative to the git root of its working
    # folder, or to the filesystem root when that folder is in no repository. Each rule therefore
    # names this task folder's exact path in every form OpenCode may use (git-relative,
    # root-relative, absolute; either slash), so a look-alike folder elsewhere never matches.
    $workDir = if ($Role -eq 'reviewer') { $Loop } else { [IO.Path]::GetFullPath($project) }
    $bases = @([IO.Path]::GetPathRoot($Loop))
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {   # no git: no repository form
        $gitRoot = git -C $workDir rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitRoot) { $bases += [IO.Path]::GetFullPath($gitRoot) }
    }
    $forms = @($Loop) + @($bases | ForEach-Object { [IO.Path]::GetRelativePath($_, $Loop) }) | Select-Object -Unique
    function Rule([string]$Sub) {
        foreach ($f in $forms) {
            $p = if ($f -eq '.') { $Sub } else { "$($f.TrimEnd('\', '/'))/$Sub" }
            $p.Replace('\', '/'); $p.Replace('/', '\')
        }
    }
    $edit = [ordered]@{}
    if ($Role -eq 'reviewer') {
        $edit['*'] = 'deny'
        foreach ($s in 'EXCHANGE/REVIEW.next.md', 'TASK.md', 'WATCHERS/scratch/*') { foreach ($p in Rule $s) { $edit[$p] = 'allow' } }
    } else {
        $edit['*'] = 'allow'
        foreach ($s in 'EXCHANGE/REVIEW.md', 'EXCHANGE/REVIEW.next.md') { foreach ($p in Rule $s) { $edit[$p] = 'deny' } }
    }
    $outside = [ordered]@{ '*' = 'deny' }
    foreach ($d in @($home_, $taskHome, $Loop, $project | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Select-Object -Unique)) { $outside["$d\**"] = 'allow'; $outside["$($d.Replace('\', '/'))/**"] = 'allow' }
    $env:OPENCODE_PERMISSION = [ordered]@{
        '*' = 'deny'; read = 'allow'; glob = 'allow'; grep = 'allow'; list = 'allow'; todowrite = 'allow'
        edit = $edit; bash = 'allow'; external_directory = $outside
    } | ConvertTo-Json -Compress -Depth 4
}

$where = if ($Role -eq 'reviewer') { 'LOOP' } else { 'PROJECT' }
$common = @('run', '--dir', "{$where}", '--format', 'json')
if ($Model) { $common += @('-m', $Model) }
if ($Variant) { $common += @('--variant', $Variant) }
$common += @([regex]::Matches($Extra, '"([^"]*)"|''([^'']*)''|(\S+)') | ForEach-Object { ($_.Groups[1..3] | Where-Object Success | Select-Object -First 1).Value })

$requested = "model=$(if ($Model) { $Model } else { '(opencode default)' })$(if ($Variant) { " variant=$Variant" }) permission=$Permission"
& (Join-Path $PSScriptRoot '../generic/agent-loop.ps1') -Loop $Loop -Role $Role -Exe $OpenCode `
    -Arguments $common -ResumeArguments ($common + @('-s', '{SESSION}')) -Session $Session `
    -SessionPattern '"sessionID":"(ses_[A-Za-z0-9]+)"' -ResumeFailurePattern 'Session not found' `
    -Requested $requested -AttachHint 'opencode --session {SESSION}' -WorkingDirectory $where `
    -AttemptTimeoutMinutes $AttemptTimeoutMinutes -MaxFailures $MaxFailures -Show:$Show -Once:$Once
$code = $LASTEXITCODE
} finally { $env:OPENCODE_PERMISSION = $callerPermission }
exit $code
