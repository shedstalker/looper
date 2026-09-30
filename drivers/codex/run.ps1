#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run a Looper role with the Codex CLI (`codex exec`), one run per due item.

.EXAMPLE
  pwsh -File drivers/codex/run.ps1 -Loop C:\work\app\.looper                          # reviewer (resumes its session across handoffs)
  pwsh -File drivers/codex/run.ps1 -Loop C:\work\app\.looper -Model gpt-6.1-sol -Effort high -Session resume -Show
  pwsh -File drivers/codex/run.ps1 -Loop C:\work\app\.looper -Role worker
  pwsh -File drivers/codex/run.ps1 -Loop C:\work\app\.looper -Local qwen3.8:27b     # local model via Ollama

  Reviewer: working root = the task folder (the only writable place); it reads the project.
  Worker:   working root = the project, plus write access to the task folder.
  -Session resume continues one Codex session across handoffs (cold start if it is gone).
  -Local <model> runs the same Codex agent on a local Ollama model (--oss), always -Session fresh.
  -Extra:"-c key=value" passes anything else to codex, on fresh and resumed runs alike (resume
  accepts -c/-m but not --add-dir). workspace-write keeps .git read-only, so a sandboxed Codex
  worker cannot commit (see README); -Sandbox danger-full-access lifts
  that - your security decision.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Loop,
    [ValidateSet('reviewer', 'worker')][string]$Role = 'reviewer',
    [string]$Model,
    [string]$Effort = '',   # passed through; Codex validates (e.g. low ... xhigh, max, ultra, per model)
    [ValidateSet('fresh', 'resume')][string]$Session = 'resume',
    [string]$Local,
    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')][string]$Sandbox = 'workspace-write',
    [string]$Codex,
    [string]$Extra = '',
    [int]$AttemptTimeoutMinutes = 60,
    [int]$MaxFailures = 3,
    [switch]$Show,
    [switch]$Once
)
$ErrorActionPreference = 'Stop'

if (-not $Codex) {
    $Codex = (Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Codex -and $env:LOCALAPPDATA) {
        # The Codex desktop app ships its CLI here on Windows.
        $Codex = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin/*/codex.exe') -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $Codex) { throw 'codex CLI not found; pass -Codex <path>.' }
}

# Settings shared by fresh and resumed runs. `exec resume` has no --sandbox/--cd, and a resumed
# session does NOT keep its sandbox (tested: it came back read-only), so pass it as config.
$common = @('--skip-git-repo-check')
if ($Local) {
    # `exec resume` rejects --oss/--local-provider, so a local model always starts fresh.
    if ($PSBoundParameters['Session'] -eq 'resume') { Write-Warning '-Local runs with -Session fresh: codex exec resume cannot select the local provider.' }
    $Session = 'fresh'; $Model = $Local
}
$fresh = @('exec', '--sandbox', $Sandbox) + $(if ($Local) { @('--oss', '--local-provider', 'ollama') } else { @() })
if ($Model) { $common += @('--model', $Model) }
if ($Effort) { $common += @('-c', "model_reasoning_effort=$Effort") }
# -Extra reaches fresh and resumed runs, so use options `codex exec resume` accepts (-c, -m, ...).
$common += @([regex]::Matches($Extra, '"([^"]*)"|''([^'']*)''|(\S+)') | ForEach-Object { ($_.Groups[1..3] | Where-Object Success | Select-Object -First 1).Value })

$fresh += $common
$resume = @('exec', 'resume') + $common + @('-c', "sandbox_mode=$Sandbox")
if ($Role -eq 'reviewer') { $fresh += @('--cd', '{LOOP}') }
else {
    $fresh += @('--cd', '{PROJECT}', '--add-dir', '{LOOP}')
    $resume += @('-c', "sandbox_workspace_write.writable_roots=['{LOOP}']")
}
$fresh += '-'                   # prompt on stdin
$resume += @('{SESSION}', '-')

# Windows only: re-own files a Codex sandbox account created, so a later sandbox identity can
# replace them (see reown.ps1). Runs before each attempt, as the user, outside the sandbox.
$reownScript = Join-Path $PSScriptRoot 'reown.ps1'
$reown = { param([string]$Folder) & $reownScript -Folder $Folder }.GetNewClosure()

$requested = (@("model=$(if ($Model) { $Model } else { '(codex default)' })", "effort=$(if ($Effort) { $Effort } else { '(codex default)' })", "sandbox=$Sandbox") + $(if ($Local) { 'provider=ollama' } else { @() })) -join ' '
& (Join-Path $PSScriptRoot '../generic/agent-loop.ps1') -Loop $Loop -Role $Role -Exe $Codex `
    -Arguments $fresh -ResumeArguments $resume -Session $Session `
    -SessionPattern '(?m)^session id: ([0-9a-f-]+)' -ResumeFailurePattern 'no rollout found|thread/resume failed' `
    -Requested $requested -Report 'model=(?m)^model: (\S+)', 'effort=(?m)^reasoning effort: (\S+)', 'provider=(?m)^provider: (\S+)', 'sandbox=(?m)^sandbox: (\S+)', 'tokens=(?m)^tokens used\s*\r?\n\s*([\d,]+)' `
    -AttachHint 'codex resume {SESSION}' -BeforeAttempt $reown `
    -WorkingDirectory $(if ($Role -eq 'reviewer') { 'LOOP' } else { 'PROJECT' }) `
    -AttemptTimeoutMinutes $AttemptTimeoutMinutes -MaxFailures $MaxFailures -Show:$Show -Once:$Once
exit $LASTEXITCODE
