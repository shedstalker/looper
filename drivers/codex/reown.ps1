#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Windows + Codex sandbox only: re-create task files owned by a Codex sandbox account as the user.

.DESCRIPTION
  Codex's Windows sandbox runs commands as separate local accounts (CodexSandbox*). Files it
  creates are owned by that account and carry only the sandbox grants that existed when they
  were written; a later sandbox identity may then be unable to replace them (seen in dogfooding:
  EXCHANGE/REVIEW.md). The Codex driver runs this before each attempt, as the user, outside the
  sandbox.

  Each affected file is copied to a temp file in the same folder, given the original's modified
  time, and renamed over the original in one step (MoveFileEx with replace). The original stays in
  place until the new file is installed; if anything fails, the original is untouched and the temp
  file is removed. Content and modified time are unchanged (creation time is not kept), so nothing
  Looper reads changes. HISTORY/ and WATCHERS/ are never touched.

  -OwnerPattern exists for tests (e.g. '.' to treat every file as affected).
#>
param(
    [Parameter(Mandatory)][string]$Folder,
    [string]$OwnerPattern = 'CodexSandbox'
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { return }

if (-not ('Looper.NativeMove' -as [type])) {
    Add-Type -Namespace Looper -Name NativeMove -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool MoveFileEx(string from, string to, int flags);
'@
}

$fixed = @(); $failed = @()
$root = (Get-Item -LiteralPath $Folder -Force).FullName.TrimEnd('\', '/')
# Judged by the path inside the task folder, so a task folder that itself sits under some
# WATCHERS/ or HISTORY/ (e.g. a reviewer's scratch) is still handled.
$files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Force |
    Where-Object { $_.FullName.Substring($root.Length) -notmatch '^[\\/](HISTORY|WATCHERS)[\\/]' -and $_.Name -notlike '.*.tmp' })
foreach ($file in $files) {
    $owner = try { (Get-Acl -LiteralPath $file.FullName).Owner } catch { '' }
    if ($owner -notmatch $OwnerPattern) { continue }
    $tmp = Join-Path $file.DirectoryName ('.' + $file.Name + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($tmp, [IO.File]::ReadAllBytes($file.FullName))
        [IO.File]::SetLastWriteTimeUtc($tmp, $file.LastWriteTimeUtc)
        # MOVEFILE_REPLACE_EXISTING (1): atomic rename over the original; the result keeps the new
        # file's owner and inherited permissions (unlike ReplaceFile, which copies the old ACL).
        if (-not [Looper.NativeMove]::MoveFileEx($tmp, $file.FullName, 1)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $fixed += $file.Name
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $failed += "$($file.Name) ($($_.Exception.Message))"
    }
}
if ($fixed) { "re-created sandbox-owned $($fixed -join ', ') as the user (content and modified time unchanged)" }
if ($failed) { "could not re-create $($failed -join '; ') - left unchanged" }
