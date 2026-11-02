# Copyright (c) 2026 taitoz
# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param(
    [string]$Destination,
    [string]$ConfigRef = 'HEAD',
    [string]$MpvVersion = 'latest',
    [string]$FFmpegVersion = 'latest',
    [string]$DownloadCache,
    [switch]$Rollback,
    [string]$BackupId,
    [switch]$PlanOnly,
    [switch]$NoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PathWithDirectory([string]$Current, [string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory) -or $Directory.Contains(';')) { throw 'Directory cannot be represented as a PATH entry. Use -NoPath.' }
    $directoryKey = $Directory.Replace('/', '\').TrimEnd('\')
    foreach ($entry in ($Current -split ';')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).Replace('/', '\').TrimEnd('\')
        if ($expanded -ieq $directoryKey) { return $Current }
    }
    if ([string]::IsNullOrEmpty($Current)) { return $Directory }
    if ($Current.EndsWith(';')) { return $Current + $Directory }
    return $Current + ';' + $Directory
}

function Add-UserPath([string]$Directory) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $updated = Get-PathWithDirectory $current $Directory
    if ($updated -cne $current) { [Environment]::SetEnvironmentVariable('Path', $updated, 'User') }
    $env:Path = Get-PathWithDirectory $env:Path $Directory
    Write-Host "User PATH includes $Directory (mpv, ffmpeg, ffprobe). Restart your terminal/IDE to refresh its environment."
}

function Get-SafePath([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '(^[\\/]|[:<>"|?*]|[. ]([\\/]|$)|(^|[\\/])\.\.?([\\/]|$)|(^|[\\/])(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])([.\\/]|$))') {
        throw "Unsafe relative path: $Relative"
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes root: $Relative" }
    $cursor = $path
    while ($cursor -and $cursor.Length -ge $base.TrimEnd('\', '/').Length) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not allowed: $cursor"
            }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $path
}

function Complete-AtomicFile([string]$Temporary, [string]$Target) {
    if (Test-Path -LiteralPath $Target) { [IO.File]::Replace($Temporary, $Target, [NullString]::Value) }
    else { [IO.File]::Move($Temporary, $Target) }
}

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $temporary = $Path + '.bootstrap-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    Complete-AtomicFile $temporary $Path
}

function Copy-AtomicFile([string]$Source, [string]$Target) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Target)) | Out-Null
    $temporary = $Target + '.bootstrap-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    Copy-Item -LiteralPath $Source -Destination $temporary
    Complete-AtomicFile $temporary $Target
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-GitBlobHash([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)" + [char]0)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([byte[]]($header + $bytes)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-CheckedProcess([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 30) {
    $quoted = foreach ($argument in $Arguments) {
        '"' + [regex]::Replace([regex]::Replace($argument, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = $quoted -join ' '
    $process.StartInfo.WorkingDirectory = Split-Path $Executable -Parent
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        $process.Start() | Out-Null
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit(5000) | Out-Null
            $stdout.Wait(1000) | Out-Null
            $stderr.Wait(1000) | Out-Null
            $output = ''
            if ($stdout.Status -eq 'RanToCompletion') { $output += $stdout.Result }
            if ($stderr.Status -eq 'RanToCompletion') { $output += $stderr.Result }
            throw "Validation timed out: $Executable`nArguments: $($process.StartInfo.Arguments)`nOutput: $output"
        }
        $output = $stdout.Result + $stderr.Result
        if ($process.ExitCode -ne 0) { throw "Validation failed ($($process.ExitCode)): $Executable`n$output" }
        return $output.Trim()
    } finally { $process.Dispose() }
}

function Invoke-MpvCheck([string]$Player, [string[]]$Arguments) {
    return Invoke-CheckedProcess $Player (@('--media-controls=no') + $Arguments)
}

function Test-MpvLua([string]$Player, [string]$Work) {
    $probe = Get-SafePath $Work 'lua-probe.lua'
    $marker = Get-SafePath $Work ('lua-ok-' + [Guid]::NewGuid().ToString('N'))
    $luaPath = $marker.Replace('\', '/')
    Write-Utf8 $probe ("local f = assert(io.open('{0}', 'w')); f:write('ok'); f:close(); require('mp').commandv('quit', '0')" -f $luaPath.Replace("'", "\'"))
    Invoke-MpvCheck $Player @('--no-config', '--idle=yes', '--vo=null', '--ao=null', "--script=$probe") | Out-Null
    if (-not (Test-Path -LiteralPath $marker)) { throw 'mpv Lua support failed.' }
}

function Get-GitHub([string]$Path) {
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Path" -Headers @{'User-Agent'='taitoz-mpv-bootstrap'; Accept='application/vnd.github+json'} -TimeoutSec 60
}

function Get-Release([string]$Repository, [string]$Version) {
    $suffix = 'latest'
    if ($Version -ne 'latest') { $suffix = 'tags/' + [Uri]::EscapeDataString($Version) }
    $release = Get-GitHub "$Repository/releases/$suffix"
    if ($release.draft -or $release.prerelease) { throw "Not a stable release: $Repository $Version" }
    return $release
}

function Select-Asset($Release, [string]$Pattern) {
    $assets = @($Release.assets | Where-Object { $_.name -match $Pattern })
    if ($assets.Count -ne 1) { throw "Expected one asset matching $Pattern; found $($assets.Count)" }
    if ($assets[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$') { throw "Missing SHA-256 digest: $($assets[0].name)" }
    return $assets[0]
}

function Save-Download([string]$Url, [string]$Path) {
    if ($Url -notmatch '^https://(github\.com|api\.github\.com|codeload\.github\.com)/') { throw "Untrusted download URL: $Url" }
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -Headers @{'User-Agent'='taitoz-mpv-bootstrap'} -TimeoutSec 900
}

function Get-VerifiedAsset($Asset, [string]$Directory) {
    $path = Get-SafePath $Directory $Asset.name
    Write-Host "Acquiring and verifying $($Asset.name)..."
    if (-not (Test-Path -LiteralPath $path)) { Save-Download $Asset.browser_download_url $path }
    if ((Get-Hash $path) -ne $Asset.digest.Substring(7).ToLowerInvariant()) { throw "SHA-256 mismatch: $($Asset.name)" }
    return $path
}

function Expand-SafeZip([string]$Archive, [string]$Directory) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $seen = @{}
        foreach ($entry in $zip.Entries) {
            $relative = $entry.FullName.Replace('/', '\').TrimEnd('\')
            if (-not $relative) { continue }
            $path = Get-SafePath $Directory $relative
            if ($seen.ContainsKey($path)) { throw "Duplicate archive entry: $relative" }
            $seen[$path] = $true
            if (($entry.ExternalAttributes -shr 16 -band 61440) -eq 40960) { throw "Archive symlink: $relative" }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                [IO.Directory]::CreateDirectory($path) | Out-Null
            } else {
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
            }
        }
    } finally { $zip.Dispose() }
}

function Copy-Tree([string]$Source, [string]$Target) {
    foreach ($file in Get-ChildItem -LiteralPath $Source -File -Recurse -Force) {
        $relative = $file.FullName.Substring($Source.TrimEnd('\', '/').Length + 1)
        $path = Get-SafePath $Target $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $path
    }
}

function Read-State([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-FileMap($State) {
    $map = @{}
    if ($null -ne $State) {
        foreach ($property in $State.files.PSObject.Properties) { $map[$property.Name] = [string]$property.Value }
    }
    return $map
}

function Assert-NotRunning([string]$Root) {
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($process in Get-Process -Name mpv, ffmpeg, ffprobe -ErrorAction SilentlyContinue) {
        if (-not $process.Path -or $process.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Close the player and processing tools before continuing (PID $($process.Id))."
        }
    }
}

function Restore-Transaction([string]$Root, [string]$Backup, [switch]$CheckChanges) {
    $journal = Read-State (Join-Path $Backup 'journal.json')
    if ($null -eq $journal) { throw 'Backup journal missing.' }
    if ($journal.status -notin @('prepared', 'complete')) { throw 'This backup has already been rolled back.' }
    foreach ($entry in $journal.entries) {
        $saved = Get-SafePath (Join-Path $Backup 'previous') $entry.path
        if ($entry.previousHash -and (-not (Test-Path -LiteralPath $saved) -or (Get-Hash $saved) -ne $entry.previousHash)) {
            throw "Backup integrity check failed: $($entry.path)"
        }
        if ($CheckChanges) {
            $target = Get-SafePath $Root $entry.path
            $current = $null
            if (Test-Path -LiteralPath $target) { $current = Get-Hash $target }
            $unchanged = $current -eq $entry.hash
            if ($journal.status -eq 'prepared') { $unchanged = $unchanged -or $current -eq $entry.previousHash }
            if (-not $unchanged) { throw "Rollback would overwrite a later change: $($entry.path)" }
        }
    }
    for ($i = $journal.entries.Count - 1; $i -ge 0; $i--) {
        $entry = $journal.entries[$i]
        $target = Get-SafePath $Root $entry.path
        $saved = Get-SafePath (Join-Path $Backup 'previous') $entry.path
        if (Test-Path -LiteralPath $saved) {
            Copy-AtomicFile $saved $target
        } elseif (Test-Path -LiteralPath $target) {
            $quarantine = Get-SafePath (Join-Path $Backup 'rolled-back-new') $entry.path
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($quarantine)) | Out-Null
            Move-Item -LiteralPath $target -Destination $quarantine
        }
    }
    $journal.status = 'rolled-back'
    Write-Utf8 (Join-Path $Backup 'journal.json') ($journal | ConvertTo-Json -Depth 8)
}

function Install-Tree([string]$Root, [string]$Payload, [string]$Backup, $Components) {
    $statePath = Get-SafePath $Root '.bootstrap/installed.json'
    $old = Read-State $statePath
    $files = Get-FileMap $old
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $conflicts = New-Object 'System.Collections.Generic.List[string]'
    $changes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in Get-ChildItem -LiteralPath $Payload -File -Recurse -Force) {
        $relative = $file.FullName.Substring($Payload.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        $target = Get-SafePath $Root $relative
        $hash = Get-Hash $file.FullName
        if (Test-Path -LiteralPath $target) {
            $current = Get-Hash $target
            if ($current -eq $hash) { $files[$relative] = $hash; continue }
            if (-not $files.ContainsKey($relative) -or $current -ne $files[$relative]) {
                if (-not $relative.StartsWith('portable_config/')) { throw "Unmanaged or modified binary/resource: $relative. Use a clean destination." }
                $incoming = Get-SafePath (Join-Path $Backup 'incoming') $relative
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($incoming)) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $incoming
                $conflicts.Add($relative)
                continue
            }
        }
        $changes.Add(@{path=$relative; source=$file.FullName; hash=$hash})
        $files[$relative] = $hash
    }
    $state = @{schema=1; installedAt=[DateTime]::UtcNow.ToString('o'); components=$Components; files=$files; conflicts=@($conflicts.ToArray()); backup=$Backup}
    $newState = Join-Path $Backup 'next-state.json'
    Write-Utf8 $newState ($state | ConvertTo-Json -Depth 12)
    $changes.Add(@{path='.bootstrap/installed.json'; source=$newState; hash=(Get-Hash $newState)})
    foreach ($change in $changes) {
        $target = Get-SafePath $Root $change.path
        $previousHash = $null
        if (Test-Path -LiteralPath $target) {
            $saved = Get-SafePath (Join-Path $Backup 'previous') $change.path
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)) | Out-Null
            Copy-Item -LiteralPath $target -Destination $saved
            $previousHash = Get-Hash $saved
        }
        $entries.Add(@{path=$change.path; hash=$change.hash; previousHash=$previousHash})
    }
    $journalPath = Join-Path $Backup 'journal.json'
    Write-Utf8 $journalPath (@{status='prepared'; entries=@($entries.ToArray())} | ConvertTo-Json -Depth 8)
    Write-Host "Applying staged files. Recovery backup: $Backup"
    try {
        foreach ($change in $changes) {
            $target = Get-SafePath $Root $change.path
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            Copy-AtomicFile $change.source $target
        }
        Write-Utf8 $journalPath (@{status='complete'; entries=@($entries.ToArray())} | ConvertTo-Json -Depth 8)
    } catch {
        Restore-Transaction $Root $Backup
        throw
    }
    foreach ($conflict in $conflicts) { Write-Warning "Preserved local file: $conflict; incoming copy is under $Backup\incoming" }
    Write-Host "Installation complete. Backup: $Backup"
}

function Invoke-Bootstrap {
    if (-not $Destination) { throw 'Specify -Destination (the directory containing mpv.exe, not portable_config).' }
    if ($env:OS -ne 'Windows_NT') { throw 'This bootstrapper requires Windows.' }
    $arch = $env:PROCESSOR_ARCHITEW6432
    if (-not $arch) { $arch = $env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64') { throw 'This initial bootstrapper supports x64 Windows only; no implicit emulation or alternate sources.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $root = [IO.Path]::GetFullPath($Destination)
    if ((Split-Path ($root.TrimEnd('\', '/')) -Leaf) -ieq 'portable_config') { throw '-Destination must be the player directory, not portable_config.' }
    $statePath = Get-SafePath $root '.bootstrap/installed.json'
    Assert-NotRunning $root
    if ($BackupId -and -not $Rollback) { throw '-BackupId requires -Rollback.' }
    if ($Rollback -and $PlanOnly) { throw '-Rollback and -PlanOnly cannot be combined.' }
    if ($Rollback) {
        $installed = Read-State $statePath
        if (-not $BackupId -and $null -eq $installed) { throw 'No installed state to roll back. For interrupted installs specify -BackupId.' }
        $backup = $null
        if ($BackupId) {
            if ($BackupId -notmatch '^[0-9]{8}T[0-9]{9}-[a-f0-9]{8}$') { throw 'Invalid backup ID.' }
            $backup = Get-SafePath $root ".bootstrap/backups/$BackupId"
        } else { $backup = Get-SafePath $root ('.bootstrap/backups/' + (Split-Path $installed.backup -Leaf)) }
        $rollbackLock = [IO.File]::Open((Get-SafePath $root '.bootstrap/install.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { Restore-Transaction $root $backup -CheckChanges }
        finally { $rollbackLock.Dispose() }
        Write-Host 'Previous files restored; newly installed files moved into the backup.'
        return
    }
    $mpv = Get-Release 'mpv-player/mpv' $MpvVersion
    $mpvAsset = Select-Asset $mpv '^mpv-.*-x86_64-pc-windows-msvc\.zip$'
    $ffmpeg = Get-Release 'GyanD/codexffmpeg' $FFmpegVersion
    $ffmpegAsset = Select-Asset $ffmpeg '^ffmpeg-.*-full_build\.zip$'
    $commit = Get-GitHub ('taitoz/mpv/commits/' + [Uri]::EscapeDataString($ConfigRef))
    $tree = Get-GitHub "taitoz/mpv/git/trees/$($commit.commit.tree.sha)?recursive=1"
    if ($tree.truncated) { throw 'Configuration tree was truncated by GitHub.' }
    if ($PlanOnly) {
        [pscustomobject]@{destination=$root; configCommit=$commit.sha; mpv=$mpvAsset.name; ffmpeg=$ffmpegAsset.name; addToUserPath=(-not $NoPath)}
        return
    }
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $work = Get-SafePath $root ".bootstrap/staging/$id"
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $lockPath = Get-SafePath $root '.bootstrap/install.lock'
    $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $backupRoot = Get-SafePath $root '.bootstrap/backups'
        if (Test-Path -LiteralPath $backupRoot) {
            foreach ($journalFile in Get-ChildItem -LiteralPath $backupRoot -Filter journal.json -Recurse) {
                if ((Read-State $journalFile.FullName).status -eq 'prepared') { throw "Interrupted update detected: $($journalFile.DirectoryName). Recover it before installing again." }
            }
        }
        $assetDirectory = $work
        if ($DownloadCache) {
            $assetDirectory = [IO.Path]::GetFullPath($DownloadCache)
            [IO.Directory]::CreateDirectory($assetDirectory) | Out-Null
        }
        $payload = Join-Path $work 'payload'
        $config = Join-Path $payload 'portable_config'
        $configZip = Join-Path $work 'config.zip'
        Write-Host "Downloading configuration commit $($commit.sha)..."
        Save-Download "https://api.github.com/repos/taitoz/mpv/zipball/$($commit.sha)" $configZip
        $configExtract = Join-Path $work 'config'
        Expand-SafeZip $configZip $configExtract
        $wrappers = @(Get-ChildItem -LiteralPath $configExtract -Directory)
        if ($wrappers.Count -ne 1) { throw 'Expected exactly one configuration archive wrapper.' }
        foreach ($item in $tree.tree) {
            if ($item.type -eq 'tree') { continue }
            if ($item.type -ne 'blob' -or $item.mode -notin @('100644', '100755')) { throw "Unsupported Git entry: $($item.path)" }
            $source = Get-SafePath $wrappers[0].FullName $item.path
            if ((Get-GitBlobHash $source) -ne $item.sha) { throw "Configuration Git blob mismatch: $($item.path)" }
            $target = Get-SafePath $config $item.path
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            Copy-Item -LiteralPath $source -Destination $target
        }
        foreach ($required in @('mpv.conf', 'input.conf', 'scripts/uosc/main.lua', 'shaders/vr-flat.glsl')) {
            if (-not (Test-Path -LiteralPath (Get-SafePath $config $required))) { throw "Missing configuration file: $required" }
        }
        $mpvZip = Get-VerifiedAsset $mpvAsset $assetDirectory
        $mpvExtract = Join-Path $work 'mpv'
        Expand-SafeZip $mpvZip $mpvExtract
        $mpvExe = @(Get-ChildItem -LiteralPath $mpvExtract -Filter mpv.exe -Recurse -File)
        if ($mpvExe.Count -ne 1) { throw 'Expected one mpv.exe.' }
        if (Test-Path -LiteralPath (Join-Path $mpvExe[0].DirectoryName 'portable_config')) { throw 'Upstream mpv archive contains a conflicting portable_config.' }
        Copy-Tree $mpvExe[0].DirectoryName $payload
        $ffmpegZip = Get-VerifiedAsset $ffmpegAsset $assetDirectory
        $ffmpegExtract = Join-Path $work 'ffmpeg'
        Expand-SafeZip $ffmpegZip $ffmpegExtract
        $ffmpegExe = @(Get-ChildItem -LiteralPath $ffmpegExtract -Filter ffmpeg.exe -Recurse -File)
        if ($ffmpegExe.Count -ne 1) { throw 'Expected one ffmpeg.exe.' }
        $ffmpegBase = Split-Path $ffmpegExe[0].DirectoryName -Parent
        $ffmpegDocs = Join-Path $payload 'licenses/ffmpeg-distribution'
        [IO.Directory]::CreateDirectory($ffmpegDocs) | Out-Null
        foreach ($item in Get-ChildItem -LiteralPath $ffmpegBase -Force) {
            if ($item.Name -eq 'bin') { continue }
            if ($item.PSIsContainer) { Copy-Tree $item.FullName (Join-Path $ffmpegDocs $item.Name) }
            else { Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $ffmpegDocs $item.Name) }
        }
        foreach ($name in @('ffmpeg.exe', 'ffprobe.exe', 'ffplay.exe')) {
            Copy-Item -LiteralPath (Join-Path $ffmpegExe[0].DirectoryName $name) -Destination (Join-Path $payload $name)
        }
        $uoscMain = Get-Content -LiteralPath (Join-Path $config 'scripts/uosc/main.lua') -Raw
        if ($uoscMain -notmatch "local uosc_version = '([0-9.]+)'") { throw 'Cannot determine bundled uosc version.' }
        $uosc = Get-Release 'tomasklaen/uosc' $Matches[1]
        $uoscAsset = Select-Asset $uosc '^uosc\.zip$'
        $uoscZip = Get-VerifiedAsset $uoscAsset $assetDirectory
        $uoscExtract = Join-Path $work 'uosc'
        Expand-SafeZip $uoscZip $uoscExtract
        $ziggy = @(Get-ChildItem -LiteralPath $uoscExtract -Filter ziggy-windows.exe -File -Recurse)
        if ($ziggy.Count -ne 1) { throw 'Expected one matching uosc Windows helper.' }
        $ziggyTarget = Get-SafePath $config 'scripts/uosc/bin/ziggy-windows.exe'
        [IO.Directory]::CreateDirectory((Split-Path $ziggyTarget -Parent)) | Out-Null
        Copy-Item -LiteralPath $ziggy[0].FullName -Destination $ziggyTarget
        Write-Utf8 (Join-Path $payload 'launch.cmd') "@echo off`r`nsetlocal`r`nset `"PATH=%~dp0;%PATH%`"`r`n`"%~dp0mpv.exe`" %*`r`n"
        $versions = @{}
        foreach ($tool in @('mpv', 'ffmpeg', 'ffprobe')) {
            $arguments = @('-version')
            if ($tool -eq 'mpv') { $arguments = @('--no-config', '--version') }
            $executable = Join-Path $payload "$tool.exe"
            if ($tool -eq 'mpv') { $versions[$tool] = Invoke-MpvCheck $executable $arguments }
            else { $versions[$tool] = Invoke-CheckedProcess $executable $arguments }
        }
        $player = Join-Path $payload 'mpv.exe'
        $capabilities = Invoke-MpvCheck $player @('--no-config', '--vo=help')
        if ($capabilities -notmatch 'gpu-next') { throw 'mpv lacks gpu-next.' }
        Test-MpvLua $player $work
        $configCheck = Invoke-MpvCheck $player @("--config-dir=$config", '--load-scripts=no', '--idle=no', '--vo=null', '--ao=null', '--save-position-on-quit=no', '--msg-level=all=warn')
        if ($configCheck -match '(?i)error parsing|unrecognized option|option .*not found') {
            throw "Configuration validation failed: $configCheck"
        }
        Assert-NotRunning $root
        $components = @{architecture='x64'; configCommit=$commit.sha; configTree=$commit.commit.tree.sha; configRef=$ConfigRef; mpv=$mpv.tag_name; mpvAsset=$mpvAsset.name; mpvDigest=$mpvAsset.digest; ffmpeg=$ffmpeg.tag_name; ffmpegAsset=$ffmpegAsset.name; ffmpegDigest=$ffmpegAsset.digest; uosc=$uosc.tag_name; uoscDigest=$uoscAsset.digest; versions=$versions}
        Install-Tree $root $payload (Get-SafePath $root ".bootstrap/backups/$id") $components
        if (-not $NoPath) {
            try { Add-UserPath $root }
            catch { Write-Warning "Files were installed, but user PATH could not be updated: $($_.Exception.Message). Add $root to user PATH manually." }
        }
        Write-Host "Launch with: $root\launch.cmd"
        Write-Warning 'Only startup, Lua, gpu-next and upstream config parsing were checked. Preserved local conflicts need manual merging. GPU decoding, VR playback and export need a media smoke test. Removed upstream files are retained for safety.'
    } finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Bootstrap }
