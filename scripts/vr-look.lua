local mp = require 'mp'

local active = false
local dragging = false
local last_x, last_y
local yaw, pitch = 0, 0

local function stop_drag()
    dragging = false
    last_x, last_y = nil, nil
end

local function update_angles()
    local opts = mp.get_property_native('glsl-shader-opts', {})
    opts.vr_yaw = string.format('%.4f', yaw)
    opts.vr_pitch = string.format('%.4f', pitch)
    mp.set_property_native('glsl-shader-opts', opts)
end

local function reset()
    stop_drag()
    yaw, pitch = 0, 0
    update_angles()
end

local function drag(event)
    if event.event == 'down' then
        local pos = mp.get_property_native('mouse-pos', {})
        dragging = pos.hover == true
        last_x, last_y = pos.x, pos.y
    elseif event.event == 'up' or event.event == 'press' then
        stop_drag()
    end
end

mp.observe_property('mouse-pos', 'native', function(_, pos)
    if not active or not dragging then return end
    if not pos or not pos.hover or not pos.x or not pos.y then
        stop_drag()
        return
    end
    if last_x and last_y then
        local dimensions = mp.get_property_native('osd-dimensions', {})
        local width = math.max((dimensions.w or 1) - (dimensions.ml or 0) - (dimensions.mr or 0), 1)
        local height = math.max((dimensions.h or 1) - (dimensions.mt or 0) - (dimensions.mb or 0), 1)
        local opts = mp.get_property_native('glsl-shader-opts', {})
        local hfov = tonumber(opts.vr_hfov) or 100
        local vfov = tonumber(opts.vr_vfov) or 60
        local projection = tonumber(opts.vr_projection) or 0
        yaw = yaw - (pos.x - last_x) * hfov / width
        if projection == 1 then
            yaw = (yaw + 180) % 360 - 180
        else
            yaw = math.max(-90, math.min(90, yaw))
        end
        pitch = math.max(-85, math.min(85, pitch - (pos.y - last_y) * vfov / height))
        update_angles()
    end
    last_x, last_y = pos.x, pos.y
end)

mp.observe_property('glsl-shaders', 'native', function(_, shaders)
    local enabled = false
    for _, path in ipairs(shaders or {}) do
        if path:gsub('\\', '/'):match('/vr%-flat%.glsl$') or path == 'vr-flat.glsl' then
            enabled = true
            break
        end
    end
    if enabled == active then return end
    active = enabled
    if active then
        reset()
        mp.add_forced_key_binding('Alt+MBTN_LEFT', 'vr-drag', drag, {complex = true})
        mp.add_forced_key_binding('Ctrl+BS', 'vr-reset', function()
            reset()
            mp.osd_message('VR: view centered')
        end)
    else
        stop_drag()
        mp.remove_key_binding('vr-drag')
        mp.remove_key_binding('vr-reset')
    end
end)

mp.register_event('file-loaded', function()
    if active then reset() end
end)
mp.register_event('end-file', stop_drag)
