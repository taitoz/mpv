# Copyright (c) 2026 taitoz
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Removes the stock Windows 11 media players so they stop competing for
# file associations:
#   - "Media Player"          (Microsoft.ZuneMusic, AppX)
#   - "Movies & TV"           (Microsoft.ZuneVideo, AppX)
#   - "Photos"                (Microsoft.Windows.Photos, AppX, optional)
#   - "Windows Media Player"  (optional feature / capability, needs admin)
#
# AppX removal works without admin for the current user. Removing the
# provisioned packages (prevents reinstall for new users / after feature
# updates) and disabling WMP12 requires an elevated shell; without admin
# those steps are reported and skipped.
#
# After removal, dead UserChoice entries are re-claimed by running
# Register-MpvForward.ps1 again (invoked automatically unless -NoRegister).
#
# Usage:
#   .\RemoveStockPlayers.ps1                   remove players, re-register
#   .\RemoveStockPlayers.ps1 -IncludePhotos    also remove Photos
#   .\RemoveStockPlayers.ps1 -WhatIf           dry run
#   .\RemoveStockPlayers.ps1 -NoRegister       do not re-run registration

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$IncludePhotos,
    [switch]$NoRegister
)

$ErrorActionPreference = 'Stop'

$appx = @('Microsoft.ZuneMusic', 'Microsoft.ZuneVideo')
if ($IncludePhotos) { $appx += 'Microsoft.Windows.Photos' }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Per-user AppX removal (no admin needed) ---------------------------------
foreach ($name in $appx) {
    $pkgs = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue
    if (-not $pkgs) {
        Write-Host "$name : not installed"
        continue
    }
    foreach ($p in $pkgs) {
        if ($PSCmdlet.ShouldProcess($p.PackageFullName, 'Remove-AppxPackage')) {
            try {
                Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                Write-Host "$name : removed for current user"
            } catch {
                Write-Warning "$name : per-user removal failed: $_"
            }
        }
    }
}

# --- Provisioned packages (admin): prevent reinstall for new users/updates ---
foreach ($name in $appx) {
    try {
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
            Where-Object DisplayName -eq $name)
    } catch {
        Write-Warning "Cannot enumerate provisioned packages (needs admin): $_"
        break
    }
    foreach ($p in $prov) {
        if ($PSCmdlet.ShouldProcess($p.PackageName, 'Remove-AppxProvisionedPackage')) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                Write-Host "$name : removed provisioned package"
            } catch {
                Write-Warning "$name : provisioned removal failed: $_"
            }
        }
    }
}

# --- Windows Media Player Legacy (WMP12) -------------------------------------
# WMP12 is a Windows component, not AppX. It exists as either an optional
# feature (older path) or a capability (Windows 11): try both, both need admin.
$wmpDone = $false
try {
    $feat = Get-WindowsOptionalFeature -Online -FeatureName 'WindowsMediaPlayer' -ErrorAction Stop
    if ($feat -and $feat.State -eq 'Enabled') {
        if ($PSCmdlet.ShouldProcess('WindowsMediaPlayer', 'Disable-WindowsOptionalFeature')) {
            $r = Disable-WindowsOptionalFeature -Online -FeatureName 'WindowsMediaPlayer' -NoRestart -ErrorAction Stop
            Write-Host "WindowsMediaPlayer : disabled (optional feature)$(if ($r.RestartNeeded) {' - restart needed'})"
            $wmpDone = $true
        }
    } elseif ($feat) {
        Write-Host "WindowsMediaPlayer : already $($feat.State)"
        $wmpDone = $true
    }
} catch {
    Write-Verbose "OptionalFeature path unavailable: $_"
}
if (-not $wmpDone) {
    try {
        $cap = Get-WindowsCapability -Online -Name 'Media.WindowsMediaPlayer*' -ErrorAction Stop |
            Where-Object State -eq 'Installed'
        foreach ($c in $cap) {
            if ($PSCmdlet.ShouldProcess($c.Name, 'Remove-WindowsCapability')) {
                $r = Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop
                Write-Host "$($c.Name) : removed (capability)$(if ($r.RestartNeeded) {' - restart needed'})"
                $wmpDone = $true
            }
        }
        if (-not $cap -and -not $wmpDone) { Write-Host 'WindowsMediaPlayer : not installed' }
    } catch {
        Write-Warning "WMP check failed (needs admin): $_"
    }
}
if (-not $isAdmin) {
    Write-Host 'Note: run elevated to also remove provisioned packages and WMP12.'
}

# --- Re-claim associations orphaned by the removed players -------------------
$register = Join-Path $PSScriptRoot 'Register-MpvForward.ps1'
if (-not $NoRegister -and (Test-Path -LiteralPath $register)) {
    Write-Host 'Re-registering mpv-forward associations...'
    & $register -NoSettingsPrompt
}

Write-Host 'Done.'
