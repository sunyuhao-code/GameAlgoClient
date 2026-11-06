local cjson = require("cjson")
local Sha256 = require("Sha256")
local prefixes = {}

-- Read committed files without invoking SDK/storage code or its callbacks.
return function(files, sessionId)
    local snapshot = require("tests.support.PersistedSnapshot")(files)
    local result = {}
    local function add(event)
        if not sessionId or event.sessionId == sessionId then table.insert(result, event) end
    end
    for key, value in pairs(snapshot.data) do
        if key:match(":events:jsonl$") then
            if type(value) == "string" then
                for line in value:gmatch("[^\r\n]+") do add(cjson.decode(line)) end
            elseif type(value) == "table" and value.format == "event_chunks_v1" then
                prefixes[key] = prefixes[key] or ("gaq_" .. Sha256.hex(key):sub(1, 24))
                local entries = {}
                for index = 1, value.blocks do
                    local best
                    for bank = 1, 2 do
                        local encoded = files[prefixes[key] .. "_" .. index .. "_" .. bank .. ".json"]
                        local ok, decoded = pcall(cjson.decode, encoded or "")
                        if ok and decoded.format == "event_chunks_v1" and
                            (not best or decoded.revision > best.revision) then best = decoded end
                    end
                    for _, row in ipairs(best and best.entries or {}) do table.insert(entries, row) end
                end
                table.sort(entries, function(a, b) return a.sequence < b.sequence end)
                for _, row in ipairs(entries) do add(cjson.decode(row.event)) end
            end
        end
    end
    return result
end
