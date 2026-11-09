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
# Compatible with PowerShell 7 and Windows PowerShell 5.1.
param([string]$Out, [switch]$Check)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$default = -not $Out
if ($default) { $Out = Join-Path $repo 'dist/looper' }
if ($Out -match '^~[\\/]') { $Out = [IO.Path]::Combine($HOME, $Out.Substring(2)) }
$Out = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Out))
if ((Split-Path -Leaf $Out) -ne 'looper') { throw "The skill folder must be named 'looper' (the skill name); got $Out" }

if ($default -and -not $Check -and (Test-Path -LiteralPath ($zip = Join-Path (Split-Path -Parent $Out) 'looper-skill.zip'))) {
    # The default zip is replaced too, so only if it is a package this script made: every entry under
    # looper/, including looper/VERSION (5.1's Compress-Archive wrote backslashes). Checked before anything changes.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $names = try { $old = [IO.Compression.ZipFile]::OpenRead($zip); try { @($old.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }) } finally { $old.Dispose() } } catch { @() }
    if (-not $names -or @($names | Where-Object { -not $_.StartsWith('looper/', [StringComparison]::Ordinal) }) -or $names -cnotcontains 'looper/VERSION') {
        throw "$zip exists and is not a generated Looper skill package, so it will not be replaced; move it away first."
    }
}
if (-not $Check -and (Test-Path -LiteralPath $Out)) {
    # The output is replaced, so only delete what this script generated (SKILL.md plus its VERSION
    # marker) or an empty folder. Anything else - the repository or a folder containing it, however
    # the path is spelled (junction, symlink, short name), or an unrelated folder - is refused.
    $version = Join-Path $Out 'VERSION'
    $generated = (Test-Path -LiteralPath (Join-Path $Out 'SKILL.md') -PathType Leaf) -and (Test-Path -LiteralPath $version -PathType Leaf) -and
        (((Get-Content -LiteralPath $version -TotalCount 1) -like 'Generated from Looper*') -or
         ((Get-Content -LiteralPath $version -TotalCount 1) -ceq 'generator: Looper skill build'))
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

function Get-Sha([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash($Bytes)) } finally { $sha.Dispose() }
}
function Invoke-Git([string[]]$GitArgs) {
    # A source export or a machine without git must still build (also on Windows PowerShell 5.1).
    try {
        $ErrorActionPreference = 'Continue'
        $value = & git -C $repo @GitArgs 2>$null
        if ($LASTEXITCODE -eq 0) { return ($value -join "`n") }
    } catch { }
}
function Get-Version {
    $repository = 'unknown'; $commit = 'unknown'; $dirty = 'unknown'; $describe = 'unknown'
    $git = 'unavailable'
    if (Get-Command git -ErrorAction SilentlyContinue) { $git = 'available' }
    # Only this checkout's own .git: a source export nested in another repository must not take its provenance.
    if ($git -eq 'available' -and (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        $value = Invoke-Git @('config', '--get', 'remote.origin.url')
        if ($value) {
            # Strip URL userinfo (including SSH usernames), query and fragment; also scp-style user@host.
            $repository = (($value -replace '(?<=://)[^/]*@', '') -replace '[?#].*$', '') -replace '^[^/:@]+@(?=[^/]+:)', ''
        }
        $value = Invoke-Git @('rev-parse', '--verify', 'HEAD')
        if ($value -match '^[0-9a-f]{40}$') { $commit = $value }
        $value = Invoke-Git @('describe', '--tags', '--always')
        if ($value) { $describe = $value }
        # Whole worktree, tracked files only: includes staged changes, excludes untracked build output.
        $value = Invoke-Git @('status', '--porcelain', '--untracked-files=no')
        if ($null -ne $value) { $dirty = ($value.Length -gt 0).ToString().ToLowerInvariant() }
    }
    @(
        'generator: Looper skill build'
        "repository: $repository"
        "commit: $commit"
        "dirty: $dirty"
        "describe: $describe"
        "date: $((Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))"
        "git: $git"
    )
}
function Assert-Version([string]$Text) {
    $pattern = @(
        'generator: Looper skill build'
        'repository: [^\r\n]+'
        'commit: (?:[0-9a-f]{40}|unknown)'
        'dirty: (?:true|false|unknown)'
        'describe: [^\r\n]+'
        'date: (?<date>[0-9]{4}-[0-9]{2}-[0-9]{2})'
        'git: (?:available|unavailable)'
    ) -join '\r?\n'
    if ($Text -cnotmatch ("\A" + $pattern + "(?:\r?\n)?\z")) { throw 'VERSION is missing or malformed' }
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Matches.date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$date)) { throw 'VERSION has an invalid date' }
}
function Assert-Manifest($Actual, [string]$Label) {
    foreach ($rel in $manifest.Keys) {
        if (-not $Actual.ContainsKey($rel)) { throw "$Label missing $rel" }
        if ($Actual[$rel] -ne $manifest[$rel]) { throw "$Label $rel differs from its source" }
    }
    foreach ($rel in $Actual.Keys) {
        if (-not $manifest.ContainsKey($rel)) { throw "$Label has unexpected file $rel" }
    }
}

# Compute the expected path set from sources, never from the existing package.
$sources = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($rel in 'SKILL.md', 'agents', 'template', 'prompts', 'tools', 'drivers', 'docs/contract.md', 'LICENSE') {
    $root = if ($rel -in 'SKILL.md', 'agents') { $PSScriptRoot } else { $repo }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root $rel) -Recurse -File -Force) {
        $path = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        $sources.Add($path, $file.FullName)
    }
}
$manifest = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($rel in $sources.Keys) { $manifest.Add($rel, (Get-Sha ([IO.File]::ReadAllBytes($sources[$rel])))) }

if (-not $Check) {
    foreach ($rel in $sources.Keys) {
        $destination = Join-Path $Out $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $sources[$rel] -Destination $destination -Force
    }
    [IO.File]::WriteAllLines((Join-Path $Out 'VERSION'), [string[]](Get-Version))  # no BOM on 5.1
    Write-Output "Looper skill written to $Out"
}

$actual = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
$versionFound = $false
foreach ($file in Get-ChildItem -LiteralPath $Out -Recurse -File -Force) {
    $rel = $file.FullName.Substring($Out.Length + 1).Replace('\', '/')
    if ($rel -ceq 'VERSION') {
        Assert-Version ([IO.File]::ReadAllText($file.FullName))
        $versionFound = $true
    } else { $actual.Add($rel, (Get-Sha ([IO.File]::ReadAllBytes($file.FullName)))) }
}
if (-not $versionFound) { throw 'packaged VERSION is missing' }
Assert-Manifest $actual 'packaged'
Write-Output "Verified $($manifest.Count) source files + VERSION ($($manifest.Count + 1) packaged files) against the repository."

if ($default) {
    $zip = Join-Path (Split-Path -Parent $Out) 'looper-skill.zip'
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (-not $Check) {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        # Compress-Archive skips Unix dotfiles. Explicit entries include hidden files on every OS.
        $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($rel in @($sources.Keys) + @('VERSION')) {
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $Out $rel), "looper/$rel") | Out-Null
            }
        } finally { $archive.Dispose() }
    }
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $actual = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        $versionFound = $false
        foreach ($entry in $archive.Entries | Where-Object { $_.Name }) {
            if (-not $entry.FullName.StartsWith('looper/', [StringComparison]::Ordinal)) { throw "unexpected zip path $($entry.FullName)" }
            $rel = $entry.FullName.Substring(7)
            $stream = $entry.Open(); $buffer = [IO.MemoryStream]::new()
            try {
                $stream.CopyTo($buffer)
                if ($rel -ceq 'VERSION') {
                    if ($versionFound) { throw 'duplicate zipped VERSION' }
                    # StreamReader handles the UTF-8 BOM emitted by Windows PowerShell 5.1.
                    $buffer.Position = 0
                    $reader = [IO.StreamReader]::new($buffer)
                    try { Assert-Version ($reader.ReadToEnd()) } finally { $reader.Dispose() }
                    $versionFound = $true
                } else { $actual.Add($rel, (Get-Sha $buffer.ToArray())) }
            } finally { $stream.Dispose(); $buffer.Dispose() }
        }
        if (-not $versionFound) { throw 'zipped VERSION is missing' }
        Assert-Manifest $actual 'zipped'
    } finally { $archive.Dispose() }
    Write-Output "Upload package ${zip}: $($manifest.Count + 1) files verified$(if (-not $Check) { ' (rebuilt)' })."
}
