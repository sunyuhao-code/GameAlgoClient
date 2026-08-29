local cjson = require("cjson")

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local files = {}
local readAttempts = 0
local missingReadAttempts = 0

FILE_READ = 1
FILE_WRITE = 2

fileSystem = {
    FileExists = function(_, name)
        return files[name] ~= nil
    end,
}

function File(name, mode)
    if mode == FILE_READ then
        readAttempts = readAttempts + 1
        if files[name] == nil then missingReadAttempts = missingReadAttempts + 1 end
    end
    local readable = mode == FILE_READ and files[name] ~= nil
    local writable = mode == FILE_WRITE
    local buffer = files[name] or ""
    return {
        IsOpen = function() return readable or writable end,
        ReadString = function() return buffer end,
        WriteString = function(_, value)
            buffer = value
            files[name] = value
        end,
        Flush = function() files[name] = buffer end,
        Close = function() end,
    }
end

local MakerAutoStorage = require("MakerAutoStorage")

local firstRunStorage = assert(MakerAutoStorage.New())
assert(firstRunStorage:IsReady() == true)
assert(readAttempts == 0, "first run must not open a missing snapshot with FILE_READ")
assert(missingReadAttempts == 0, "first run attempted to read a missing snapshot")

firstRunStorage:SetItem("stable_user_id", "maker-user-001")
local persisted = cjson.decode(assert(files["gamealgo_sdk_storage_v1.json"]))
assert(persisted.data.stable_user_id == "maker-user-001")

local secondRunStorage = assert(MakerAutoStorage.New())
assert(secondRunStorage:IsReady() == true)
assert(readAttempts == 1, "second run must read the existing local snapshot")
assert(missingReadAttempts == 0, "existing snapshot recovery must not read a missing file")
assert(secondRunStorage:GetItem("stable_user_id") == "maker-user-001")

print("Maker automatic storage first-run tests passed")
