# Copyright (c) 2026 taitoz
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Registers mpv-forward.exe as a video file handler on Windows 11 (HKCU only,
# no admin required). For every video extension it creates a ProgId with an
# open verb pointing at mpv-forward.exe, registers the application via
# Capabilities + RegisteredApplications so it appears in "Default apps" and
# in "Open with", and adds an "Open with mpv-forward" context menu verb.
#
# Windows 11 note: extensions that already have a user-chosen default
# (FileExts\<ext>\UserChoice) are hash-protected. By default this script
# claims them via SetUserFTA.exe (third-party, personal-use only), which is
# looked up next to this script / next to mpv.exe and auto-downloaded from
# setuserfta.com when absent. Pass -NoForce to register Open With entries
# only and finish defaults manually in Settings > Apps > Default apps.
#
# Usage:
#   .\Register-MpvForward.ps1                    register + force all video defaults
#   .\Register-MpvForward.ps1 -NoForce           register without claiming defaults
#   .\Register-MpvForward.ps1 -WhatIf            dry run
#   .\Register-MpvForward.ps1 -Unregister        remove all registrations
#   .\Register-MpvForward.ps1 -ExePath D:\mpv\mpv-forward.exe

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ExePath,
    [string]$SetUserFta,
    [string]$ProgIdPrefix = 'mpv-forward',
    [string[]]$Extensions = @(
        # core (uosc video_types)
        '3g2','3gp','asf','avi','divx','f4v','flv','h264','h265','hevc',
        'm2t','m2ts','m4v','mkv','mov','mp4','mp4v','mpeg','mpg','mts',
        'ogm','ogv','rm','rmvb','ts','vob','webm','wmv','y4m',
        # extended containers/codecs
        '3gp2','3gpp','3gpp2','amv','bik','bik2','d2v','dav','drc','dv',
        'dvr-ms','evo','fli','flc','hdmov','ifo','ivf','m1v','m2v','mjp',
        'mjpeg','mjpg','mk3d','mod','mp2v','mpe','mpv','mpg4','mqv','mxf',
        'nsv','nut','nuv','pva','qt','r3d','rec','smk','smv','swf',
        'thp','tod','trp','ty','vc1','vid','vro','wvx','xesc','yuv',
        'prores','wtv','tp','dif'
    ),
    [switch]$Unregister,
    [switch]$NoForce,
    [switch]$NoContextMenu,
    [switch]$NoSettingsPrompt
)

$ErrorActionPreference = 'Stop'

# powershell -File passes "a,b,c" as one string; split comma lists either way
# and normalize "*.ext"/".ext" inputs down to bare extension names.
$Extensions = @($Extensions | ForEach-Object { $_ -split ',' } | ForEach-Object { ($_.Trim() -replace '^[*.]+|[*.]+$','').ToLower() } | Where-Object { $_ })

# --- Locate mpv-forward.exe --------------------------------------------------
if (-not $ExePath) {
    # tools/mpv-forward -> portable_config -> player directory
    $ExePath = Join-Path $PSScriptRoot '..\..\..\mpv-forward.exe'
}
$ExePath = [System.IO.Path]::GetFullPath($ExePath)
if (-not $Unregister -and -not (Test-Path -LiteralPath $ExePath)) {
    throw "mpv-forward.exe not found: $ExePath (pass -ExePath)"
}

$classes   = 'HKCU:\Software\Classes'
$fileExts  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
$appKey    = "$classes\Applications\mpv-forward.exe"
$regApps   = 'HKCU:\Software\RegisteredApplications'
$icon      = '"' + $ExePath + '",0'
$openCmd   = '"' + $ExePath + '" "%1"'

# SetUserFTA.exe (third-party, personal-use only) computes the protected
# UserChoice hash so extensions already owned by another app can be claimed
# without the manual Default apps step. Looked up next to this script, then
# next to mpv.exe; downloaded from setuserfta.com when absent.
$SetUserFtaVersion = '1.8.3'
$SetUserFtaUrl     = "https://setuserfta.com/SetUserFTA_v$SetUserFtaVersion.zip"
$useFta            = -not $NoForce -and -not $Unregister

function Get-SetUserFta {
    if (-not $PSCmdlet.ShouldProcess($SetUserFtaUrl, 'download SetUserFTA')) { return $null }
    $zip = Join-Path $env:TEMP "SetUserFTA_v$SetUserFtaVersion.zip"
    $tmp = Join-Path $env:TEMP ("setuserfta-" + [guid]::NewGuid().ToString('n'))
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        Write-Host "Downloading $SetUserFtaUrl ..."
        Invoke-WebRequest -Uri $SetUserFtaUrl -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'SetUserFTA.exe' | Select-Object -First 1
        if (-not $src) { throw 'SetUserFTA.exe not found inside the archive' }
        $dst = Join-Path $PSScriptRoot 'SetUserFTA.exe'
        Copy-Item -LiteralPath $src.FullName -Destination $dst -Force
        Write-Host "Saved $dst"
        return $dst
    } catch {
        Write-Warning "SetUserFTA download failed: $_"
        return $null
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($useFta -and -not $SetUserFta) {
    foreach ($c in @("$PSScriptRoot\SetUserFTA.exe", "$PSScriptRoot\..\..\..\SetUserFTA.exe")) {
        if (Test-Path -LiteralPath $c) { $SetUserFta = $c; break }
    }
}
if ($useFta -and (-not $SetUserFta -or -not (Test-Path -LiteralPath $SetUserFta))) {
    $SetUserFta = Get-SetUserFta
}
if ($useFta -and -not $SetUserFta) {
    Write-Warning 'SetUserFTA.exe unavailable; UserChoice defaults not forced.'
    $useFta = $false
}

function Set-Key {
    param([string]$Path, [string]$Value)
    if ($PSCmdlet.ShouldProcess($Path, 'create/update registry key')) {
        New-Item -Path $Path -Force | Out-Null
        if ($null -ne $Value) {
            New-ItemProperty -Path $Path -Name '(Default)' -Value $Value -PropertyType String -Force | Out-Null
        }
    }
}

function Set-Value {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'String')
    if ($PSCmdlet.ShouldProcess("$Path\$Name", 'set registry value')) {
        New-Item -Path $Path -Force | Out-Null
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
}

function Remove-Key {
    param([string]$Path)
    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'remove registry key')) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Register-Extension([string]$Ext) {
    $ext      = ".$Ext"
    $progId   = "$ProgIdPrefix$ext"
    $extKey   = "$classes\$ext"
    $progKey  = "$classes\$progId"

    Set-Key $progKey "mpv-forward video ($ext)"
    Set-Key "$progKey\DefaultIcon" $icon
    Set-Key "$progKey\shell\open\command" $openCmd

    # Default ProgId - honored for extensions without a UserChoice entry.
    Set-Key $extKey $progId

    # List in "Open with": the canonical HKCR location plus the
    # Explorer-managed FileExts location.
    Set-Value "$extKey\OpenWithProgids" $progId ([byte[]]@()) 'Binary'
    Set-Value "$fileExts\$ext\OpenWithProgids" $progId ([byte[]]@()) 'Binary'

    # "Open with mpv-forward" context menu verb.
    if (-not $NoContextMenu) {
        $verb = "$classes\SystemFileAssociations\$ext\shell\mpv-forward"
        Set-Key $verb 'Open with mpv-forward'
        Set-Value $verb 'Icon' $icon
        Set-Key "$verb\command" $openCmd
    }

    # Force the default via UserChoice (third-party hash tool). SetUserFTA
    # quirks observed on Windows 11: it exits 0 even when the UserChoice was
    # not written, occasionally hangs, and leaves a junk '..ext' staging key
    # behind. Run it with a timeout, verify the registry, retry, clean up.
    if ($useFta -and $PSCmdlet.ShouldProcess("$ext UserChoice", 'SetUserFTA')) {
        $done = $false
        foreach ($attempt in 1..3) {
            $p = [Diagnostics.Process]::Start($SetUserFta, "$ext $progId")
            if (-not $p.WaitForExit(20000)) {
                try { $p.Kill() } catch {}
                $p.WaitForExit()
            }
            $p.Dispose()
            $uc = Get-ItemProperty "$fileExts\$ext\UserChoice" -ErrorAction SilentlyContinue
            if ($uc -and $uc.ProgId -eq $progId) { $done = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if ($done) { $script:forced++ } else { $script:forceFailed += $Ext }
        $junkUc = Get-ItemProperty "$fileExts\..$Ext\UserChoice" -ErrorAction SilentlyContinue
        if ($junkUc -and $junkUc.ProgId -eq $progId) {
            Remove-Item -LiteralPath "$fileExts\..$Ext" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# SystemFileAssociations\video covers every file with PerceivedType=video,
# regardless of extension.
function Register-VideoClass {
    $cls = "$classes\SystemFileAssociations\video"
    Set-Value "$cls\OpenWithProgids" "$ProgIdPrefix.video" ([byte[]]@()) 'Binary'
    if (-not $NoContextMenu) {
        Set-Key "$cls\shell\mpv-forward" 'Open with mpv-forward'
        Set-Value "$cls\shell\mpv-forward" 'Icon' $icon
        Set-Key "$cls\shell\mpv-forward\command" $openCmd
    }
}

function Unregister-VideoClass {
    $cls = "$classes\SystemFileAssociations\video"
    if ((Test-Path -LiteralPath "$cls\OpenWithProgids") -and
            $PSCmdlet.ShouldProcess("$cls\OpenWithProgids\$ProgIdPrefix.video", 'remove registry value')) {
        Remove-ItemProperty -LiteralPath "$cls\OpenWithProgids" -Name "$ProgIdPrefix.video" -Force -ErrorAction SilentlyContinue
    }
    Remove-Key "$cls\shell\mpv-forward"
}

function Unregister-Extension([string]$Ext) {
    $ext    = ".$Ext"
    $progId = "$ProgIdPrefix$ext"
    $extKey = "$classes\$ext"

    Remove-Key "$classes\$progId"
    if ((Test-Path -LiteralPath "$classes\$ext\OpenWithProgids") -and
            $PSCmdlet.ShouldProcess("$classes\$ext\OpenWithProgids\$progId", 'remove registry value')) {
        Remove-ItemProperty -LiteralPath "$classes\$ext\OpenWithProgids" -Name $progId -Force -ErrorAction SilentlyContinue
        $owp = Get-Item -LiteralPath "$classes\$ext\OpenWithProgids"
        if ($owp.ValueCount -eq 0) {
            Remove-Item -LiteralPath "$classes\$ext\OpenWithProgids" -Force
        }
    }

    # Only clear the default ProgId if it still points at us. The registry
    # default value has an empty name; Remove-ItemProperty cannot reach it,
    # so the .NET Registry API is used.
    $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Classes\$ext", $true)
    if ($regKey) {
        try {
            $cur = $regKey.GetValue('')
            if ($cur -eq $progId -and
                    $PSCmdlet.ShouldProcess("$extKey (default)", 'clear registry value')) {
                $regKey.DeleteValue('')
            }
        } finally {
            $regKey.Close()
        }
    }
    $item = Get-Item -LiteralPath $extKey -ErrorAction SilentlyContinue
    if ($item -and $item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
        if ($PSCmdlet.ShouldProcess($extKey, 'remove empty extension key')) {
            Remove-Item -LiteralPath $extKey -Force
        }
    }
    if ((Test-Path -LiteralPath "$fileExts\$ext\OpenWithProgids") -and
            $PSCmdlet.ShouldProcess("$fileExts\$ext\OpenWithProgids\$progId", 'remove registry value')) {
        Remove-ItemProperty -LiteralPath "$fileExts\$ext\OpenWithProgids" -Name $progId -Force -ErrorAction SilentlyContinue
    }
    # SetUserFTA '..ext' staging leftovers carrying our ProgId.
    $junkUc = Get-ItemProperty "$fileExts\..$Ext\UserChoice" -ErrorAction SilentlyContinue
    if ($junkUc -and $junkUc.ProgId -eq $progId -and
            $PSCmdlet.ShouldProcess("$fileExts\..$Ext", 'remove SetUserFTA staging key')) {
        Remove-Item -LiteralPath "$fileExts\..$Ext" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Key "$classes\SystemFileAssociations\$ext\shell\mpv-forward"
}

function Notify-AssocChanged {
    $sig = '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);'
    $t = Add-Type -MemberDefinition $sig -Name 'Shcn' -Namespace 'Win32' -PassThru
    $t::SHChangeNotify(0x08000000, 0, [System.IntPtr]::Zero, [System.IntPtr]::Zero) # SHCNE_ASSOCCHANGED
}

if ($Unregister) {
    Write-Warning 'UserChoice entries cannot be removed (Windows ACL); reset them manually in Default apps if needed.'
    foreach ($e in $Extensions) { Unregister-Extension $e }
    Unregister-VideoClass
    Remove-Key "$classes\$ProgIdPrefix.video"
    Remove-Key $appKey
    if ((Test-Path -LiteralPath $regApps) -and
            $PSCmdlet.ShouldProcess("$regApps\mpv-forward", 'remove registry value')) {
        Remove-ItemProperty -LiteralPath $regApps -Name 'mpv-forward' -Force -ErrorAction SilentlyContinue
    }
    Notify-AssocChanged
    Write-Host 'mpv-forward unregistered.'
    return
}

# Generic ProgId used for the SystemFileAssociations\video class entry.
Set-Key "$classes\$ProgIdPrefix.video" 'mpv-forward video'
Set-Key "$classes\$ProgIdPrefix.video\DefaultIcon" $icon
Set-Key "$classes\$ProgIdPrefix.video\shell\open\command" $openCmd

# Application capabilities -> shows up in Settings > Default apps and "Open with".
Set-Key "$appKey\shell\open\command" $openCmd
Set-Key "$appKey\DefaultIcon" $icon
Set-Value $appKey 'FriendlyAppName' 'mpv-forward'
Set-Value "$appKey\Capabilities" 'ApplicationName' 'mpv-forward'
Set-Value "$appKey\Capabilities" 'ApplicationDescription' 'Single-instance launcher shim for mpv'

$script:forced = 0
$script:forceFailed = @()
foreach ($e in $Extensions) {
    $ext = ".$e"
    Set-Value "$appKey\SupportedTypes" $ext ''
    Set-Value "$appKey\Capabilities\FileAssociations" $ext "$ProgIdPrefix$ext"
    Register-Extension $e
}

Set-Value $regApps 'mpv-forward' 'SOFTWARE\Classes\Applications\mpv-forward.exe\Capabilities'
Register-VideoClass
Notify-AssocChanged

Write-Host ("Registered mpv-forward.exe for {0} video extension(s).`n  Exe: {1}" -f $Extensions.Count, $ExePath)
if ($useFta) {
    Write-Host ("UserChoice forced via SetUserFTA (verified): {0} ok, {1} failed" -f $script:forced, $script:forceFailed.Count)
    if ($script:forceFailed) { Write-Host ("Failed: " + ($script:forceFailed -join ', ')) }
} else {
    Write-Host 'Extensions without an existing default now open in mpv-forward.'
    Write-Host 'On stock Windows 11 most video types are already owned by Media Player,'
    Write-Host 'so finish in Settings > Apps > Default apps > mpv-forward.'
    Write-Host 'If mpv-forward is missing from some lists, sign out and back in to'
    Write-Host 'refresh the association cache.'
}

if (-not $NoSettingsPrompt -and -not ($useFta -and $script:forceFailed.Count -eq 0)) {
    Start-Process 'ms-settings:defaultapps'
}
