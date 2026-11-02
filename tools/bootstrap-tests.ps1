# Copyright (c) 2026 taitoz
# SPDX-License-Identifier: GPL-3.0-or-later
param([string]$MpvExecutable)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\bootstrap.ps1"

function Assert-Equal($Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "Expected [$Expected], got [$Actual]" }
}

function Assert-Throws([scriptblock]$Action) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    if (-not $thrown) { throw 'Expected failure.' }
}

Assert-Throws { Get-PathWithDirectory 'C:\Other' '' }
Assert-Throws { Get-PathWithDirectory 'C:\Other' 'C:\Tools;mpv' }
Assert-Equal (Get-PathWithDirectory '' 'C:\Tools\mpv') 'C:\Tools\mpv'
Assert-Equal (Get-PathWithDirectory $null 'C:\Tools\mpv') 'C:\Tools\mpv'
Assert-Equal (Get-PathWithDirectory 'C:\Other' 'C:\Tools\mpv') 'C:\Other;C:\Tools\mpv'
Assert-Equal (Get-PathWithDirectory 'C:\Other;' 'C:\Tools\mpv') 'C:\Other;C:\Tools\mpv'
Assert-Equal (Get-PathWithDirectory 'C:\Other;"c:/TOOLS/mpv/";C:\Last' 'C:\Tools\mpv') 'C:\Other;"c:/TOOLS/mpv/";C:\Last'
Assert-Equal (Get-PathWithDirectory ' C:\Tools\mpv\ ;C:\Other' 'C:\Tools\mpv') ' C:\Tools\mpv\ ;C:\Other'
Assert-Equal (Get-PathWithDirectory 'C:\Tools\mpv-extra' 'C:\Tools\mpv') 'C:\Tools\mpv-extra;C:\Tools\mpv'
Assert-Equal (Get-PathWithDirectory '%USERPROFILE%\mpv' (Join-Path $env:USERPROFILE 'mpv')) '%USERPROFILE%\mpv'
$once = Get-PathWithDirectory 'C:\Other' 'C:\Tools\mpv'
Assert-Equal (Get-PathWithDirectory $once 'C:\Tools\mpv') $once

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mpv-bootstrap-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
foreach ($unsafe in @('../escape', 'C:\escape', '/escape', 'foo:bar', 'a/../escape', 'a./b', 'NUL.txt', 'a/CON', 'x?/y')) {
    Assert-Throws { Get-SafePath $testRoot $unsafe }
}
Assert-Equal (Get-SafePath $testRoot 'portable_config/mpv.conf') (Join-Path $testRoot 'portable_config\mpv.conf')

$blob = Join-Path $testRoot 'blob'
Write-Utf8 $blob "hello`n"
Assert-Equal (Get-GitBlobHash $blob) 'ce013625030ba8dba906f756967f9e9ca394464a'
$hostExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
Assert-Equal (Invoke-CheckedProcess $hostExecutable @('-NoProfile', '-Command', "Write-Output 'fixture'")) 'fixture'
Assert-Throws { Invoke-CheckedProcess $hostExecutable @('-NoProfile', '-Command', 'exit 37') }
$timeoutError = ''
try { Invoke-CheckedProcess $hostExecutable @('-NoProfile', '-Command', "[Console]::Out.WriteLine('timeout-output'); [Console]::Out.Flush(); Start-Sleep -Seconds 10") 2 | Out-Null }
catch { $timeoutError = $_.Exception.Message }
if ($timeoutError -notmatch 'Validation timed out:' -or $timeoutError -notmatch 'Arguments:' -or $timeoutError -notmatch 'Output: timeout-output') {
    throw "Missing timeout diagnostics: $timeoutError"
}
Assert-Throws { Select-Asset ([pscustomobject]@{assets=@()}) '.*' }
Assert-Throws { Select-Asset ([pscustomobject]@{assets=@([pscustomobject]@{name='mpv.zip'; digest='sha256:bad'})}) 'mpv' }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path $testRoot 'unsafe.zip'
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try { $zip.CreateEntry('../escaped.txt') | Out-Null } finally { $zip.Dispose() }
Assert-Throws { Expand-SafeZip $zipPath (Join-Path $testRoot 'extracted') }
Assert-Equal (Test-Path -LiteralPath (Join-Path $testRoot 'escaped.txt')) $false

$validZipPath = Join-Path $testRoot 'valid.zip'
$zip = [IO.Compression.ZipFile]::Open($validZipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $entry = $zip.CreateEntry('wrapper/config.txt')
    $writer = New-Object IO.StreamWriter($entry.Open())
    try { $writer.Write('archive-data') } finally { $writer.Dispose() }
} finally { $zip.Dispose() }
Expand-SafeZip $validZipPath (Join-Path $testRoot 'valid-extracted')
Assert-Equal (Get-Content -LiteralPath (Join-Path $testRoot 'valid-extracted/wrapper/config.txt') -Raw) 'archive-data'

function Save-Download([string]$Url, [string]$Path) { Write-Utf8 $Path 'download-data' }
$asset = [pscustomobject]@{name='download.zip'; browser_download_url='https://github.com/test/fixture'; digest=('sha256:' + ('0' * 64))}
Assert-Throws { Get-VerifiedAsset $asset $testRoot }
$asset.digest = 'sha256:' + (Get-Hash (Join-Path $testRoot 'download.zip'))
Assert-Equal (Get-VerifiedAsset $asset $testRoot) (Join-Path $testRoot 'download.zip')

$payload = Join-Path $testRoot 'payload'
$root = Join-Path $testRoot 'destination with spaces'
Write-Utf8 (Join-Path $payload 'mpv.exe') 'binary-one'
Write-Utf8 (Join-Path $payload 'portable_config/mpv.conf') 'config-one'
Write-Utf8 (Join-Path $payload 'portable_config/scripts/example.lua') 'script-one'
$backup1 = Join-Path $root '.bootstrap/backups/first'
Install-Tree $root $payload $backup1 @{version='one'}
Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'mpv.exe') -Raw) 'binary-one'
Assert-Equal (Test-Path -LiteralPath (Join-Path $root 'portable_config/scripts/example.lua')) $true
$state1 = Read-State (Join-Path $root '.bootstrap/installed.json')
Assert-Equal $state1.components.version 'one'

Write-Utf8 (Join-Path $root 'portable_config/mpv.conf') 'user-config'
Write-Utf8 (Join-Path $root 'portable_config/user.txt') 'user-file'
Write-Utf8 (Join-Path $payload 'portable_config/mpv.conf') 'config-two'
Write-Utf8 (Join-Path $payload 'portable_config/scripts/example.lua') 'script-two'
Write-Utf8 (Join-Path $payload 'mpv.exe') 'binary-two'
Write-Utf8 (Join-Path $payload 'portable_config/new.conf') 'new-file'
$backup2 = Join-Path $root '.bootstrap/backups/second'
Install-Tree $root $payload $backup2 @{version='two'}
Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'portable_config/mpv.conf') -Raw) 'user-config'
Assert-Equal (Get-Content -LiteralPath (Join-Path $backup2 'incoming/portable_config/mpv.conf') -Raw) 'config-two'
Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'portable_config/scripts/example.lua') -Raw) 'script-two'
Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'portable_config/user.txt') -Raw) 'user-file'
Assert-Equal @((Read-State (Join-Path $root '.bootstrap/installed.json')).conflicts).Count 1

Write-Utf8 (Join-Path $root 'mpv.exe') 'local-binary'
Assert-Throws { Install-Tree $root $payload (Join-Path $root '.bootstrap/backups/refused') @{} }
Assert-Throws { Restore-Transaction $root $backup2 -CheckChanges }
Write-Utf8 (Join-Path $root 'mpv.exe') 'binary-two'
Restore-Transaction $root $backup2 -CheckChanges
Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'mpv.exe') -Raw) 'binary-one'
Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'portable_config/scripts/example.lua') -Raw) 'script-one'
Assert-Equal (Get-Content -LiteralPath (Join-Path $root 'portable_config/mpv.conf') -Raw) 'user-config'
Assert-Equal (Test-Path -LiteralPath (Join-Path $root 'portable_config/new.conf')) $false
Assert-Equal (Test-Path -LiteralPath (Join-Path $backup2 'rolled-back-new/portable_config/new.conf')) $true
Assert-Equal (Read-State (Join-Path $root '.bootstrap/installed.json')).components.version 'one'
Assert-Throws { Restore-Transaction $root $backup2 -CheckChanges }

$adopt = Join-Path $testRoot 'existing'
Write-Utf8 (Join-Path $adopt 'portable_config/mpv.conf') 'preexisting-config'
Install-Tree $adopt $payload (Join-Path $adopt '.bootstrap/backups/adopt') @{}
Assert-Equal (Get-Content -LiteralPath (Join-Path $adopt 'portable_config/mpv.conf') -Raw) 'preexisting-config'

$recover = Join-Path $testRoot 'recovery'
$recoveryBackup = Join-Path $recover '.bootstrap/backups/recover'
Write-Utf8 (Join-Path $recover 'old.txt') 'old'
Write-Utf8 (Join-Path $recoveryBackup 'previous/old.txt') 'old'
$oldHash = Get-Hash (Join-Path $recover 'old.txt')
$journal = @{status='prepared'; entries=@(@{path='old.txt'; previousHash=$oldHash; hash=('a' * 64)}, @{path='not-yet-created.txt'; previousHash=$null; hash=('b' * 64)})}
Write-Utf8 (Join-Path $recoveryBackup 'journal.json') ($journal | ConvertTo-Json -Depth 8)
Restore-Transaction $recover $recoveryBackup -CheckChanges
Assert-Equal (Get-Content -LiteralPath (Join-Path $recover 'old.txt') -Raw) 'old'
$tamperRoot = Join-Path $testRoot 'tamper'
$originalPayload = Join-Path $testRoot 'tamper-payload'
Write-Utf8 (Join-Path $originalPayload 'mpv.exe') 'first'
Install-Tree $tamperRoot $originalPayload (Join-Path $tamperRoot '.bootstrap/backups/first') @{}
Write-Utf8 (Join-Path $originalPayload 'mpv.exe') 'second'
$tamperBackup = Join-Path $tamperRoot '.bootstrap/backups/second'
Install-Tree $tamperRoot $originalPayload $tamperBackup @{}
Write-Utf8 (Join-Path $tamperBackup 'previous/mpv.exe') 'corrupt-backup'
Assert-Throws { Restore-Transaction $tamperRoot $tamperBackup -CheckChanges }
Assert-Equal (Get-Content -LiteralPath (Join-Path $tamperRoot 'mpv.exe') -Raw) 'second'

$failRoot = Join-Path $testRoot 'failed-copy'
$failPayload = Join-Path $testRoot 'fail-payload'
Write-Utf8 (Join-Path $failPayload 'mpv.exe') 'first'
Write-Utf8 (Join-Path $failPayload 'portable_config/mpv.conf') 'first'
Install-Tree $failRoot $failPayload (Join-Path $failRoot '.bootstrap/backups/first') @{}
Write-Utf8 (Join-Path $failPayload 'mpv.exe') 'second'
Write-Utf8 (Join-Path $failPayload 'portable_config/mpv.conf') 'second'
$script:failOnce = $true
$script:failureTarget = Join-Path $failRoot 'portable_config/mpv.conf'
function Copy-Item {
    param($LiteralPath, $Destination, [switch]$Force)
    if ($script:failOnce -and $Destination.StartsWith($script:failureTarget + '.bootstrap-')) {
        $script:failOnce = $false
        throw 'Simulated interrupted copy.'
    }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
Assert-Throws { Install-Tree $failRoot $failPayload (Join-Path $failRoot '.bootstrap/backups/failed') @{} }
Assert-Equal (Get-Content -LiteralPath (Join-Path $failRoot 'mpv.exe') -Raw) 'first'
Assert-Equal (Get-Content -LiteralPath (Join-Path $failRoot 'portable_config/mpv.conf') -Raw) 'first'
Assert-Equal (Read-State (Join-Path $failRoot '.bootstrap/backups/failed/journal.json')).status 'rolled-back'
if ($MpvExecutable) {
    $version = Invoke-MpvCheck $MpvExecutable @('--no-config', '--version')
    if ($version -notmatch 'mpv ') { throw 'Missing mpv version output.' }
    for ($i = 1; $i -le 30; $i++) { Test-MpvLua $MpvExecutable (Join-Path $testRoot "lua-$i") }
    $config = Join-Path (Split-Path $MpvExecutable -Parent) 'portable_config'
    $result = Invoke-MpvCheck $MpvExecutable @("--config-dir=$config", '--load-scripts=no', '--idle=no', '--vo=null', '--ao=null', '--save-position-on-quit=no', '--msg-level=all=warn')
    if ($result -match '(?i)error parsing|unrecognized option|option .*not found') { throw $result }
    Write-Host '30 real mpv Lua checks and config validation passed.'
}
function Invoke-CheckedProcess([string]$Executable, [string[]]$Arguments) { return $Arguments -join ' ' }
Assert-Equal (Invoke-MpvCheck 'fixture.exe' @('--no-config', '--version')) '--media-controls=no --no-config --version'
Write-Host "All bootstrap tests passed. Fixtures retained at $testRoot"
