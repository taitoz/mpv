-- VR profile detection for mpv (ffprobe metadata + filename fallback)
-- Copyright (c) 2026 taitoz
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

local mp = require 'mp'
local utils = require 'mp.utils'
local options = {ffprobe = 'ffprobe', timeout = 10}
require('mp.options').read_options(options, 'vr-detect')

local function normalize(value)
    return tostring(value or ''):lower():gsub('[%s%-]+', '_')
end

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

local function metadata_profile(data)
    local stream = (data.streams or {})[1]
    if not stream then return nil end
    local tags = {}
    for k, v in pairs((data.format or {}).tags or {}) do tags[k:lower()] = v end
    for k, v in pairs(stream.tags or {}) do tags[k:lower()] = v end
    local projection = normalize(tags.vr_projection or tags.projection)
    local stereo = normalize(tags.stereo_mode or tags.stereo_layout)
    local fov = tonumber(tags.vr_fov or tags.id_fov)
    local unsupported = false
    for _, side in ipairs(stream.side_data_list or {}) do
        if side.side_data_type == 'Spherical Mapping' then
            if projection == '' then projection = normalize(side.projection) end
            if (tonumber(side.yaw) or 0) ~= 0 or (tonumber(side.pitch) or 0) ~= 0 or (tonumber(side.roll) or 0) ~= 0 then
                unsupported = true
            end
            for _, key in ipairs({'bound_left', 'bound_right', 'bound_top', 'bound_bottom'}) do
                if (tonumber(side[key]) or 0) ~= 0 then unsupported = true end
            end
        elseif side.side_data_type == 'Stereo 3D' and stereo == '' then
            stereo = normalize(side.type)
        end
    end
    if unsupported then return nil, 'Spherical rotation/crop is not supported; using filename fallback' end
    if projection == '' then return nil end
    local layout
    if stereo == 'left_right' or stereo == 'right_left' or stereo == 'side_by_side' or stereo == 'sbs' then
        layout = 'sbs'
    elseif stereo == 'top_bottom' or stereo == 'bottom_top' or stereo == 'top_and_bottom' or stereo == 'tb' or stereo == 'over_under' then
        layout = 'tb'
    elseif stereo == '' or stereo == 'mono' or stereo == '2d' then
        layout = 'mono'
    else
        return nil, 'Unsupported stereo layout: ' .. stereo
    end
    if projection == 'fisheye' or projection == 'fisheye190' or projection == 'fisheye200' then
        fov = fov or tonumber(projection:match('(%d+)$'))
        if layout == 'sbs' and (fov == 190 or fov == 200) then return 'fisheye' .. fov end
        return nil, 'Fisheye metadata requires SBS and an explicit 190/200 degree FOV'
    end
    local half = projection == 'hequirect' or projection == 'half_equirectangular' or projection == 'vr180' or projection == 'equirectangular180'
    local full = projection == 'equirectangular' or projection == 'equirect' or projection == '360'
    if not half and not full then return nil, 'Unsupported projection: ' .. projection end
    if half then
        if layout == 'sbs' then return 'vr180' end
        return '180-' .. layout
    end
    if layout == 'tb' then return 'tb' end
    return '360-' .. layout
end

mp.add_hook('on_load', 20, function(hook)
    hook:defer()
    mp.set_property_native('user-data/vr-profile', 'pending')
    local path = mp.get_property('path', '')
    local fallback = filename_profile(mp.get_property('filename', ''))
    local finished = false
    local request, timer
    local function finish(profile, source)
        if finished then return end
        finished = true
        if timer then timer:kill() end
        mp.set_property_native('user-data/vr-profile', profile)
        mp.set_property_native('user-data/vr-detection-source', source)
        mp.msg.info('VR detection: ' .. profile .. ' (' .. source .. ')')
        hook:cont()
    end
    if not mp.get_property('filename', ''):lower():match('%.mp4$') then
        finish('none', 'non-MP4 input; VR disabled')
        return
    end
    if path:find('://', 1, true) or path == '-' then
        finish(fallback, 'filename; non-local input skipped')
        return
    end
    if not utils.file_info(path) then
        finish(fallback, 'filename; local file unavailable')
        return
    end
    timer = mp.add_timeout(options.timeout, function()
        if request then mp.abort_async_command(request) end
        mp.msg.warn('ffprobe timed out; using filename fallback')
        finish(fallback, 'filename; ffprobe timeout')
    end)
    request = mp.command_native_async({
        name = 'subprocess',
        args = {options.ffprobe, '-v', 'error', '-select_streams', 'v:0',
            '-show_entries', 'stream_tags:stream_side_data:format_tags', '-of', 'json', '-i', path},
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(success, result)
        if finished then return end
        if not success or not result or result.status ~= 0 then
            mp.msg.warn('ffprobe failed; using filename fallback. Check ffprobe in PATH.')
            finish(fallback, 'filename; ffprobe failed')
            return
        end
        local data = utils.parse_json(result.stdout or '')
        if type(data) ~= 'table' then
            mp.msg.warn('Invalid ffprobe JSON; using filename fallback')
            finish(fallback, 'filename; invalid ffprobe JSON')
            return
        end
        local profile, reason = metadata_profile(data)
        if reason then mp.msg.warn(reason) end
        finish(profile or fallback, profile and 'metadata' or 'filename; no usable VR metadata')
    end)
end)
