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
# (FileExts\<ext>\UserChoice) cannot be taken over programmatically - the
# hash check resets tampered entries. For those, finish in
# Settings > Apps > Default apps > mpv-forward (opened automatically).
#
# Usage:
#   .\Register-MpvForward.ps1                    register for all video types
#   .\Register-MpvForward.ps1 -WhatIf            dry run
#   .\Register-MpvForward.ps1 -Unregister        remove all registrations
#   .\Register-MpvForward.ps1 -ExePath D:\mpv\mpv-forward.exe

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ExePath,
    [string]$ProgIdPrefix = 'mpv-forward',
    [string[]]$Extensions = @(
        '3g2','3gp','asf','avi','divx','f4v','flv','h264','h265','hevc',
        'm2t','m2ts','m4v','mkv','mov','mp4','mp4v','mpeg','mpg','mts',
        'ogm','ogv','rm','rmvb','ts','vob','webm','wmv','y4m'
    ),
    [switch]$Unregister,
    [switch]$NoContextMenu,
    [switch]$NoSettingsPrompt
)

$ErrorActionPreference = 'Stop'

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

    # List in "Open with".
    Set-Value "$fileExts\$ext\OpenWithProgids" $progId ([byte[]]@()) 'Binary'

    # "Open with mpv-forward" context menu verb.
    if (-not $NoContextMenu) {
        $verb = "$classes\SystemFileAssociations\$ext\shell\mpv-forward"
        Set-Key $verb 'Open with mpv-forward'
        Set-Value $verb 'Icon' $icon
        Set-Key "$verb\command" $openCmd
    }
}

function Unregister-Extension([string]$Ext) {
    $ext    = ".$Ext"
    $progId = "$ProgIdPrefix$ext"
    $extKey = "$classes\$ext"

    Remove-Key "$classes\$progId"

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
    Remove-Key "$classes\SystemFileAssociations\$ext\shell\mpv-forward"
}

function Notify-AssocChanged {
    $sig = '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, int uFlags, System.IntPtr dwItem1, System.IntPtr dwItem2);'
    $t = Add-Type -MemberDefinition $sig -Name 'Shcn' -Namespace 'Win32' -PassThru
    $t::SHChangeNotify(0x08000000, 0, [System.IntPtr]::Zero, [System.IntPtr]::Zero) # SHCNE_ASSOCCHANGED
}

if ($Unregister) {
    foreach ($e in $Extensions) { Unregister-Extension $e }
    Remove-Key $appKey
    if ((Test-Path -LiteralPath $regApps) -and
            $PSCmdlet.ShouldProcess("$regApps\mpv-forward", 'remove registry value')) {
        Remove-ItemProperty -LiteralPath $regApps -Name 'mpv-forward' -Force -ErrorAction SilentlyContinue
    }
    Notify-AssocChanged
    Write-Host 'mpv-forward unregistered.'
    return
}

# Application capabilities -> shows up in Settings > Default apps and "Open with".
Set-Key "$appKey\shell\open\command" $openCmd
Set-Key "$appKey\DefaultIcon" $icon
Set-Value $appKey 'FriendlyAppName' 'mpv-forward'
Set-Value "$appKey\Capabilities" 'ApplicationName' 'mpv-forward'
Set-Value "$appKey\Capabilities" 'ApplicationDescription' 'Single-instance launcher shim for mpv'

foreach ($e in $Extensions) {
    $ext = ".$e"
    Set-Value "$appKey\SupportedTypes" $ext ''
    Set-Value "$appKey\Capabilities\FileAssociations" $ext "$ProgIdPrefix$ext"
    Register-Extension $e
}

Set-Value $regApps 'mpv-forward' 'SOFTWARE\Classes\Applications\mpv-forward.exe\Capabilities'
Notify-AssocChanged

Write-Host ("Registered mpv-forward.exe for {0} video extension(s).`n  Exe: {1}" -f $Extensions.Count, $ExePath)
Write-Host 'Extensions without an existing default now open in mpv-forward.'
Write-Host 'For extensions already taken by another app, finish in Default apps:'
Write-Host '  Settings > Apps > Default apps > mpv-forward'

if (-not $NoSettingsPrompt) {
    Start-Process 'ms-settings:defaultapps'
}
