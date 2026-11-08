-- Single-instance forwarding: when a second mpv starts, it connects to the
-- IPC pipe (input-ipc-server), asks the peer for its pid and, if the peer is
-- a different process, forwards its playlist via loadfile and quits.
-- Requires input-ipc-server=\\.\pipe\mpvsocket in mpv.conf.
local PIPE = [[\\.\pipe\mpvsocket]]

local function get_peer_pid()
    local f = io.open(PIPE, "r+")
    if not f then
        return nil
    end
    f:write('{"command":["get_property","pid"]}\n')
    f:flush()
    local resp = f:read("*l")
    f:close()
    return resp and tonumber(resp:match('"data":(%d+)'))
end

local peer = get_peer_pid()
local own = tonumber(mp.get_property("pid") or "")
if peer and own and peer ~= own then
    local out = io.open(PIPE, "w")
    if out then
        local function esc(s)
            return s:gsub("\\", "\\\\"):gsub('"', '\\"')
        end
        local pl = mp.get_property_native("playlist") or {}
        local sent = 0
        for _, e in ipairs(pl) do
            if e.filename then
                local mode = sent == 0 and "replace" or "append-play"
                out:write(string.format('{"command":["loadfile","%s","%s"]}\n', esc(e.filename), mode))
                sent = sent + 1
            end
        end
        out:close()
        mp.msg.warn("another mpv instance detected (pid " .. peer .. "), forwarded " .. sent .. " file(s)")
    end
    mp.command("quit")
end
