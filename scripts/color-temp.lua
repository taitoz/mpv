-- Color temperature control for shaders/color-temp.glsl
-- Copyright (c) 2026 taitoz
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- Keys (bound from input.conf):
--   script-message color-temp <delta_k>   shift temperature by N kelvin
--   script-message color-temp-reset       back to neutral 6500K

local mp = require 'mp'

local SHADER = '~~/shaders/color-temp.glsl'
local NEUTRAL = 6500
local temp = NEUTRAL

local function apply()
    local opts = mp.get_property_native('glsl-shader-opts', {})
    opts.ctemp = tostring(temp)
    mp.set_property_native('glsl-shader-opts', opts)
end

local function ensure_shader()
    local list = mp.get_property_native('glsl-shaders', {})
    for _, s in ipairs(list) do
        if s:gsub('\\', '/'):match('/color%-temp%.glsl$') then
            apply()
            return
        end
    end
    table.insert(list, SHADER)
    mp.set_property_native('glsl-shaders', list)
    apply()
end

mp.register_script_message('color-temp', function(delta)
    ensure_shader()
    temp = math.max(1500, math.min(20000, temp + (tonumber(delta) or 0)))
    apply()
    mp.osd_message(('Color temperature: %d K'):format(temp))
end)

mp.register_script_message('color-temp-reset', function()
    temp = NEUTRAL
    apply()
    mp.osd_message('Color temperature: 6500 K (neutral)')
end)

mp.register_event('file-loaded', ensure_shader)
