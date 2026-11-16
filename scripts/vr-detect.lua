-- VR profile selection for mpv (filename detection + manual toggle/cycling)
-- Copyright (c) 2026 taitoz
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

local mp = require 'mp'

local function filename_profile(name)
    name = name:lower()
    local function has(text) return name:find(text, 1, true) ~= nil end
    if has('fisheye200') or has('mkx200') then return 'fisheye200' end
    if has('fisheye') or has('mkx') then return 'fisheye190' end
    local function token(text)
        return name:find('%f[%w]' .. text .. '%f[%W]') ~= nil
    end
    local half = token('180') or has('vr180') or has('180f') or token('180x180')
    local full = token('360') or has('vr360')
    local vertical = token('3dv') or token('ou') or token('tb')
    local horizontal = token('3dh') or token('sbs')
    if vertical and half then return '180-tb' end
    if vertical and full then return 'tb' end
    if horizontal and half then return 'vr180' end
    if horizontal and full then return '360-sbs' end
    if has('_tb') then return 'tb' end
    if has('vr180') or has('180_sbs') or has('180f') then return 'vr180' end
    return 'none'
end

-- Last active VR mode; fallback when toggle-on cannot detect one.
local last_mode = 'vr180'

-- Instant filename-only detection; metadata probing was removed to avoid
-- delaying playback start. VR detection is restricted to .mp4 filenames.
mp.add_hook('on_load', 20, function()
    local profile = 'none'
    if mp.get_property('filename', ''):lower():match('%.mp4$') then
        profile = filename_profile(mp.get_property('filename', ''))
    end
    mp.set_property_native('user-data/vr-profile', profile)
    mp.set_property_native('user-data/vr-detection-source', 'filename')
    if profile ~= 'none' then
        last_mode = profile
        mp.msg.info('VR detection: ' .. profile .. ' (filename)')
    end
end)

local function set_profile(mode, source)
    mp.set_property_native('user-data/vr-profile', mode)
    mp.set_property_native('user-data/vr-detection-source', source)
    mp.osd_message('VR profile: ' .. mode)
end

-- Toggle flat preview on/off. When turning on, the mode is detected from the
-- filename (any extension, not just .mp4); if detection fails, the last used
-- mode is restored.
mp.add_key_binding('toggle', function()
    local cur = mp.get_property('user-data/vr-profile', 'none')
    if cur ~= 'none' then
        last_mode = cur
        set_profile('none', 'manual')
        return
    end
    local detected = filename_profile(mp.get_property('filename', ''))
    set_profile(detected ~= 'none' and detected or last_mode,
        detected ~= 'none' and 'manual+filename' or 'manual')
end)

-- Manual profile cycling (script-binding vr-detect/cycle[-back]).
local order = {'vr180', '360-sbs', '180-tb', 'tb', '360-mono', '180-mono',
    'fisheye190', 'fisheye200', 'none'}

local function cycle(direction)
    local cur = mp.get_property('user-data/vr-profile', 'none')
    local idx = 0
    for i, v in ipairs(order) do
        if v == cur then idx = i break end
    end
    local mode = order[((idx + direction - 1) % #order) + 1]
    if mode ~= 'none' then last_mode = mode end
    set_profile(mode, 'manual')
end

mp.add_key_binding('cycle', function() cycle(1) end)
mp.add_key_binding('cycle-back', function() cycle(-1) end)
