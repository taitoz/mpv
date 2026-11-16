-- Copy ffprobe metadata of the current file to the clipboard (Ctrl+i).
-- Copyright (c) 2026 taitoz
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

local mp = require 'mp'

local options = {ffprobe = 'ffprobe', timeout = 15}
require('mp.options').read_options(options, 'ffprobe-info')

local pending = nil

local function copy_probe()
    local path = mp.get_property('path', '')
    if path == '' or path == '-' then
        mp.osd_message('ffprobe: no file loaded')
        return
    end
    if pending then
        mp.osd_message('ffprobe: already running')
        return
    end
    local state = {done = false, request = nil, timer = nil}
    pending = state
    mp.osd_message('Running ffprobe...', 2)
    state.timer = mp.add_timeout(options.timeout, function()
        if state.done then return end
        state.done = true
        if state.request then mp.abort_async_command(state.request) end
        if pending == state then pending = nil end
        mp.osd_message('ffprobe: timed out')
    end)
    state.request = mp.command_native_async({
        name = 'subprocess',
        args = {options.ffprobe, '-v', 'error', '-show_format', '-show_streams',
            '-of', 'json', path},
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, result)
        if state.done then return end
        state.done = true
        state.timer:kill()
        if pending == state then pending = nil end
        if not success or not result or result.status ~= 0 or (result.stdout or '') == '' then
            mp.msg.error('ffprobe failed: ' .. tostring(result and result.stderr or success))
            mp.osd_message('ffprobe: failed (see console)')
            return
        end
        local bytes = #result.stdout
        if mp.set_property('clipboard/text', result.stdout) then
            mp.osd_message('ffprobe metadata copied (' .. bytes .. ' bytes)')
        else
            mp.osd_message('ffprobe: clipboard unavailable')
        end
    end)
end

mp.add_key_binding(nil, 'copy', copy_probe)
