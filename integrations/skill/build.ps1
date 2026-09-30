#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Generate the Looper Agent Skill from the canonical repository files.

.EXAMPLE
  pwsh -File integrations/skill/build.ps1                     # -> dist/looper/ and dist/looper-skill.zip
  pwsh -File integrations/skill/build.ps1 -Out ~/.claude/skills/looper      # Claude Code (personal)
  pwsh -File integrations/skill/build.ps1 -Out ~/.agents/skills/looper      # Codex (personal)
  pwsh -File integrations/skill/build.ps1 -Check     # verify an existing dist/ package is current

  One package targets Claude Code and Codex (tested) and ChatGPT surfaces that support skill upload
  (not yet exercised): SKILL.md (open Agent Skills
  format), agents/openai.yaml (OpenAI UI metadata, ignored elsewhere), and generated copies of
  template/, prompts/, tools/, drivers/, docs/contract.md and LICENSE. The zip is for apps that
  install a skill by upload. The skill is a copy, never a fork: rebuild after changing Looper.
#>
param([string]$Out, [switch]$Check)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$default = -not $Out
if ($default) { $Out = Join-Path $repo 'dist/looper' }
$Out = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Out))
if ((Split-Path -Leaf $Out) -ne 'looper') { throw "The skill folder must be named 'looper' (the skill name); got $Out" }

if (-not $Check) {
if (Test-Path -LiteralPath $Out) {
    # The output is replaced, so only delete what this script generated (SKILL.md plus its VERSION
    # line) or an empty folder. Anything else - the repository or a folder containing it, however
    # the path is spelled (junction, symlink, short name), or an unrelated folder - is refused.
    $version = Join-Path $Out 'VERSION'
    $generated = (Test-Path -LiteralPath (Join-Path $Out 'SKILL.md') -PathType Leaf) -and (Test-Path -LiteralPath $version -PathType Leaf) -and
        ((Get-Content -LiteralPath $version -TotalCount 1) -like 'Generated from Looper*')
    $empty = (Test-Path -LiteralPath $Out -PathType Container) -and @(Get-ChildItem -LiteralPath $Out -Force).Count -eq 0
    if (-not ($generated -or $empty)) { throw "-Out $Out exists and is not a generated Looper skill, so it will not be replaced; choose another folder, or remove it yourself if it is an old copy." }
    # Even a generated package must not hold this build's own source (e.g. a checkout placed inside
    # it). Drop a unique marker next to this script and look for it in -Out; with no links inside
    # -Out, that search sees every real file, whatever the paths are called.
    $links = @(Get-ChildItem -LiteralPath $Out -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links) { throw "-Out $Out contains a link ($($links[0].FullName)), so it will not be replaced; remove it yourself." }
    $marker = Join-Path $PSScriptRoot ('.build-guard-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($marker, '') } catch { throw "Cannot check that -Out $Out does not hold this repository (cannot write in $PSScriptRoot); remove the old package yourself." }
    try { $holdsSource = @(Get-ChildItem -LiteralPath $Out -Recurse -Force -Filter (Split-Path -Leaf $marker)).Count -gt 0 }
    finally { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
    if ($holdsSource) { throw "-Out $Out holds this Looper repository, so it will not be replaced; choose a folder outside it." }
    Remove-Item -LiteralPath $Out -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'docs') | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SKILL.md') -Destination $Out
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'agents') -Destination $Out -Recurse
foreach ($dir in 'template', 'prompts', 'tools', 'drivers') {
    Copy-Item -LiteralPath (Join-Path $repo $dir) -Destination $Out -Recurse
}
Copy-Item -LiteralPath (Join-Path $repo 'docs/contract.md') -Destination (Join-Path $Out 'docs')
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $Out
$commit = try { (& git -C $repo describe --tags --always 2>$null) } catch { '' }
Set-Content -LiteralPath (Join-Path $Out 'VERSION') -Value "Generated from Looper $commit on $((Get-Date).ToString('yyyy-MM-dd'))"
Write-Output "Looper skill written to $Out"
}

function Get-SourcePath([string]$Relative) {
    # Where each packaged file comes from in the repository.
    switch -Regex ($Relative) {
        '^(SKILL\.md|agents/.*)$' { return Join-Path $PSScriptRoot $Relative }
        default { return Join-Path $repo $Relative }
    }
}
function Get-Sha([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)) } finally { $sha.Dispose() }
}

# Self-check: every packaged file must equal its canonical source, byte for byte.
$files = @(Get-ChildItem -LiteralPath $Out -Recurse -File | Where-Object Name -ne 'VERSION')
foreach ($f in $files) {
    $rel = $f.FullName.Substring($Out.Length + 1).Replace('\', '/')
    if ((Get-Sha ([IO.File]::ReadAllBytes($f.FullName))) -ne (Get-Sha ([IO.File]::ReadAllBytes((Get-SourcePath $rel))))) { throw "packaged $rel differs from its source" }
}
Write-Output "Verified $($files.Count) packaged files against the repository."

if ($default) {
    $zip = Join-Path (Split-Path -Parent $Out) 'looper-skill.zip'
    if (-not $Check) {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path $Out -DestinationPath $zip   # zip holds the looper/ folder
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $checked = 0
        foreach ($entry in $archive.Entries | Where-Object { $_.Name -and $_.Name -ne 'VERSION' }) {
            $rel = $entry.FullName.Replace('\', '/') -replace '^looper/', ''
            $stream = $entry.Open(); $buffer = [IO.MemoryStream]::new()
            try { $stream.CopyTo($buffer) } finally { $stream.Dispose() }
            if ((Get-Sha $buffer.ToArray()) -ne (Get-Sha ([IO.File]::ReadAllBytes((Get-SourcePath $rel))))) { throw "zipped $rel differs from its source" }
            $checked++
        }
    } finally { $archive.Dispose() }
    Write-Output "Upload package ${zip}: $checked files verified against the repository$(if (-not $Check) { " (rebuilt)" })."
}
