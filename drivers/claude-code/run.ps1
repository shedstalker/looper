#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run a Looper role with Claude Code headless (`claude -p`), one run per due item.

.EXAMPLE
  pwsh -File drivers/claude-code/run.ps1 -Loop C:\work\app\.looper              # reviewer (resumes its session across handoffs)
  pwsh -File drivers/claude-code/run.ps1 -Loop C:\work\app\.looper -Model claude-opus-5-5 -Effort high -Session resume
  pwsh -File drivers/claude-code/run.ps1 -Loop C:\work\app\.looper -Role worker
  pwsh -File drivers/claude-code/run.ps1 -Loop C:\work\app\.looper -Local qwen36-64k     # local model via Ollama

  Permission mode: reviewer dontAsk (anything not allowed is refused, never a hanging prompt);
  worker acceptEdits. Both may run git and pwsh. Widen with -Extra:"--allowedTools 'Bash(npm test *)'".
  -Session resume continues one Claude session across handoffs (cold start if it is gone).
  Claude Code reports the model it used but not the effort level; the log says so.
  -Local <model> points Claude Code at Ollama's Anthropic-compatible endpoint (no key needed).
  The model needs a large context window (Claude Code's prompt is big): see README.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Loop,
    [ValidateSet('reviewer', 'worker')][string]$Role = 'reviewer',
    [string]$Model,
    [string]$Effort = '',   # passed through; Claude Code validates (e.g. low, medium, high, xhigh, max)
    [ValidateSet('fresh', 'resume')][string]$Session = 'resume',
    [string]$Local,
    [string]$Claude,
    [string]$Extra = '',
    [int]$AttemptTimeoutMinutes = 60,
    [int]$MaxFailures = 3,
    [switch]$Show,
    [switch]$Once
)
$ErrorActionPreference = 'Stop'

if (-not $Claude) {
    $Claude = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Claude) {
        $candidate = Join-Path $HOME '.local/bin/claude.exe'
        if (Test-Path $candidate) { $Claude = $candidate } else { throw 'claude CLI not found; pass -Claude <path>.' }
    }
}

# -Local changes these for the child; restored below so a run in the caller's session leaves no trace.
$callerEnv = @{}
foreach ($n in 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY') { $callerEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
if ($Local) {
    # Ollama serves an Anthropic-compatible API.
    $env:ANTHROPIC_BASE_URL = if ($env:OLLAMA_HOST) { "http://$($env:OLLAMA_HOST -replace '^https?://', '')" } else { 'http://localhost:11434' }
    $env:ANTHROPIC_AUTH_TOKEN = 'ollama'
    $env:ANTHROPIC_API_KEY = ''
    $Model = $Local
}
$common = @('-p', '--output-format', 'json', '--add-dir', '{HOME}')
if ($Role -eq 'reviewer') {
    $common += @('--permission-mode', 'dontAsk', '--add-dir', '{PROJECT}',
        '--allowedTools', 'Read,Grep,Glob,Write,Edit,PowerShell,Bash(pwsh *),Bash(sh *),Bash(git *)')
} else {
    $common += @('--permission-mode', 'acceptEdits', '--add-dir', '{LOOP}',
        '--allowedTools', 'Read,Grep,Glob,Write,Edit,PowerShell,Bash(pwsh *),Bash(sh *),Bash(git *)')
}
if ($Model) { $common += @('--model', $Model) }
if ($Effort) { $common += @('--effort', $Effort) }
$common += @([regex]::Matches($Extra, '"([^"]*)"|''([^'']*)''|(\S+)') | ForEach-Object { ($_.Groups[1..3] | Where-Object Success | Select-Object -First 1).Value })

try {
$requested = "model=$(if ($Model) { $Model } else { '(claude default)' }) effort=$(if ($Effort) { $Effort } else { '(claude default)' })$(if ($Local) { ' provider=ollama' })"
& (Join-Path $PSScriptRoot '../generic/agent-loop.ps1') -Loop $Loop -Role $Role -Exe $Claude `
    -Arguments $common -ResumeArguments ($common + @('--resume', '{SESSION}')) -Session $Session `
    -SessionPattern '"session_id":"([^"]+)"' -ResumeFailurePattern 'No conversation found with session ID' `
    -Requested $requested -Report 'model="([^"]+)":\{"inputTokens"', 'effort=(?!)' `
    -AttachHint 'claude --resume {SESSION}' `
    -WorkingDirectory $(if ($Role -eq 'reviewer') { 'LOOP' } else { 'PROJECT' }) `
    -AttemptTimeoutMinutes $AttemptTimeoutMinutes -MaxFailures $MaxFailures -Show:$Show -Once:$Once
$code = $LASTEXITCODE
} finally { foreach ($n in $callerEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $callerEnv[$n]) } }
exit $code
