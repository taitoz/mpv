# Copyright (c) 2026 taitoz
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copies the icon resources (RT_GROUP_ICON + RT_ICON) from mpv.exe into
# mpv-forward.exe so the launcher shares mpv's icon in Explorer, the taskbar
# and file associations. Pure Win32 resource APIs - no external tools.
#
# Usage:
#   .\Copy-MpvIcon.ps1                              # defaults: mpv.exe / mpv-forward.exe in player dir
#   .\Copy-MpvIcon.ps1 -Target .\bin\mpv-forward.exe

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Target
)

$ErrorActionPreference = 'Stop'

if (-not $Source) { $Source = Join-Path $PSScriptRoot '..\..\..\mpv.exe' }
if (-not $Target) { $Target = Join-Path $PSScriptRoot '..\..\..\mpv-forward.exe' }
$Source = [System.IO.Path]::GetFullPath($Source)
$Target = [System.IO.Path]::GetFullPath($Target)
foreach ($p in @($Source, $Target)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "not found: $p" }
}

if (-not ('IconRes' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class IconRes
{
    const uint LOAD_LIBRARY_AS_DATAFILE = 0x00000002;
    const uint LOAD_LIBRARY_AS_IMAGE    = 0x00000020;
    static readonly IntPtr RT_ICON       = (IntPtr)3;
    static readonly IntPtr RT_GROUP_ICON = (IntPtr)14;

    delegate bool EnumResNameProc(IntPtr hModule, IntPtr lpszType, IntPtr lpszName, IntPtr lParam);
    delegate bool EnumResLangProc(IntPtr hModule, IntPtr lpszType, IntPtr lpszName, ushort wIDLanguage, IntPtr lParam);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibraryEx(string lpFileName, IntPtr hFile, uint dwFlags);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr hModule);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumResourceNames(IntPtr hModule, IntPtr lpszType, EnumResNameProc lpEnumFunc, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumResourceLanguages(IntPtr hModule, IntPtr lpszType, IntPtr lpszName, EnumResLangProc lpEnumFunc, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindResource(IntPtr hModule, IntPtr lpName, IntPtr lpType);
    [DllImport("kernel32.dll")] static extern IntPtr LoadResource(IntPtr hModule, IntPtr hResInfo);
    [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr hResData);
    [DllImport("kernel32.dll")] static extern uint SizeofResource(IntPtr hModule, IntPtr hResInfo);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr BeginUpdateResource(string pFileName, bool bDeleteExistingResources);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);

    static Win32Exception LastError(string what)
    {
        return new Win32Exception(Marshal.GetLastWin32Error(), what);
    }

    static byte[] ReadRes(IntPtr lib, IntPtr hres)
    {
        if (hres == IntPtr.Zero) throw LastError("FindResource");
        IntPtr p = LockResource(LoadResource(lib, hres));
        uint n = SizeofResource(lib, hres);
        if (p == IntPtr.Zero || n == 0) throw new Win32Exception("empty resource");
        byte[] b = new byte[n];
        Marshal.Copy(p, b, 0, (int)n);
        return b;
    }

    public static void Copy(string sourcePath, string targetPath)
    {
        IntPtr lib = LoadLibraryEx(sourcePath, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE);
        if (lib == IntPtr.Zero) throw LastError("LoadLibraryEx " + sourcePath);
        try
        {
            var groups = new List<IntPtr>();
            EnumResNameProc enumNames = (h, t, n, lp) => { groups.Add(n); return true; };
            EnumResourceNames(lib, RT_GROUP_ICON, enumNames, IntPtr.Zero);
            if (groups.Count == 0) throw new Win32Exception("no icon group in " + sourcePath);
            IntPtr groupName = groups[0];

            byte[] group = ReadRes(lib, FindResource(lib, groupName, RT_GROUP_ICON));
            int count = BitConverter.ToUInt16(group, 4);
            var icons = new List<KeyValuePair<IntPtr, byte[]>>();
            for (int i = 0; i < count; i++)
            {
                IntPtr id = (IntPtr)(int)BitConverter.ToUInt16(group, 6 + i * 14 + 12);
                icons.Add(new KeyValuePair<IntPtr, byte[]>(id, ReadRes(lib, FindResource(lib, id, RT_ICON))));
            }

            var langs = new List<ushort>();
            EnumResLangProc enumLangs = (h, t, n, l, lp) => { langs.Add(l); return true; };
            EnumResourceLanguages(lib, RT_GROUP_ICON, groupName, enumLangs, IntPtr.Zero);
            ushort lang = langs.Count > 0 ? langs[0] : (ushort)0;

            IntPtr upd = BeginUpdateResource(targetPath, true);
            if (upd == IntPtr.Zero) throw LastError("BeginUpdateResource " + targetPath);
            bool ok = UpdateResource(upd, RT_GROUP_ICON, groupName, lang, group, (uint)group.Length);
            foreach (var kv in icons)
                ok = UpdateResource(upd, RT_ICON, kv.Key, lang, kv.Value, (uint)kv.Value.Length) && ok;
            if (!EndUpdateResource(upd, !ok)) throw LastError("EndUpdateResource");
            if (!ok) throw new Win32Exception("UpdateResource failed");
        }
        finally { FreeLibrary(lib); }
    }
}
'@
}

[IconRes]::Copy($Source, $Target)
Write-Host "Copied icon: $Source -> $Target"
