local cjson = require("cjson")

-- Inspect both committed snapshot banks without invoking SDK recovery code.
return function(files)
    local best, filename
    for _, name in ipairs({ "gamealgo_sdk_storage_v1.json", "gamealgo_sdk_storage_v1.backup.json" }) do
        local ok, value = pcall(cjson.decode, files[name] or "")
        if ok and type(value) == "table" and value.schemaVersion == 1 and type(value.data) == "table"
            and (not best or value.revision > best.revision) then
            best, filename = value, name
        end
    end
    return assert(best, "no valid persisted SDK snapshot"), filename
end
