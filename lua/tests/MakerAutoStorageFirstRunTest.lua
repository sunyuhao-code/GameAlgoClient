local cjson = require("cjson")

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local files = {}
local readAttempts = 0
local missingReadAttempts = 0
local writes = 0
local failWrites = false
local failWriteName = nil
local writesByName = {}

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
            if failWrites then error("simulated local write failure") end
            if name == failWriteName then
                files[name] = value:sub(1, 20)
                error("simulated interrupted chunk write")
            end
            writes = writes + 1
            writesByName[name] = (writesByName[name] or 0) + 1
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
local persisted = require("tests.support.PersistedSnapshot")(files)
assert(persisted.data.stable_user_id == "maker-user-001")

local secondRunStorage = assert(MakerAutoStorage.New())
assert(secondRunStorage:IsReady() == true)
assert(readAttempts == 2, "second run must inspect both existing snapshot banks")
assert(missingReadAttempts == 0, "existing snapshot recovery must not read a missing file")
assert(secondRunStorage:GetItem("stable_user_id") == "maker-user-001")

-- Repeated identity checks must not rewrite the whole snapshot or dirty cloud
-- storage. A changed value still persists synchronously and syncs normally.
local cloudWrites = 0
clientCloud = {
    Get = function() error("existing local storage must not reload cloud") end,
    Set = function(_, _, _, callbacks)
        cloudWrites = cloudWrites + 1
        callbacks.ok()
    end,
}
local savedWrites = writes
local savedRevision = secondRunStorage:Diagnostics().revision
for _ = 1, 100 do
    assert(secondRunStorage:SetItem("stable_user_id", "maker-user-001"))
    secondRunStorage:Flush()
end
assert(writes == savedWrites, "unchanged scalar values must not rewrite local storage")
assert(secondRunStorage:Diagnostics().revision == savedRevision)
assert(cloudWrites == 0, "unchanged values must not cause cloud writes")
assert(secondRunStorage:SetItem("stable_user_id", "maker-user-002"))
assert(writes == savedWrites + 1, "changed identity must persist immediately")
secondRunStorage:Flush()
assert(cloudWrites == 1)
secondRunStorage:SetItem("stable_user_id", "maker-user-002")
secondRunStorage:Flush()
assert(cloudWrites == 1, "an acknowledged value must not be uploaded again")

-- Equality in memory does not prove a failed write reached disk. Both another
-- SetItem with the same value and an explicit Flush must retry local storage.
failWrites = true
assert(secondRunStorage:SetItem("retry_value", "pending") == false)
local beforeFailure = files["gamealgo_sdk_storage_v1.json"]
assert(cjson.decode(beforeFailure).data.retry_value == nil)
failWrites = false
assert(secondRunStorage:SetItem("retry_value", "pending"))
assert(require("tests.support.PersistedSnapshot")(files).data.retry_value == "pending")
failWrites = true
assert(secondRunStorage:SetItem("retry_value", "flush-pending") == false)
failWrites = false
secondRunStorage:Flush()
assert(require("tests.support.PersistedSnapshot")(files).data.retry_value == "flush-pending")

-- Mutable tables retain SetItem's existing behavior even when their reference
-- is unchanged; the scalar shortcut must not suppress updates inside a table.
local mutable = { value = 1 }
secondRunStorage:SetItem("mutable", mutable)
mutable.value = 2
secondRunStorage:SetItem("mutable", mutable)
assert(require("tests.support.PersistedSnapshot")(files).data.mutable.value == 2)
clientCloud = nil

-- Backlogs live in independent, bounded chunks, with immutable cloud jobs.
local Sha256 = require("Sha256")
local queueKey = "test:game:user:events:jsonl"
local prefix = "gaq_" .. Sha256.hex(queueKey):sub(1, 24)
local storage = assert(MakerAutoStorage.New())
local queue = storage:EventQueue(queueKey)
local events = {}
for index = 1, 250 do
    events[index] = { eventId = "chunk-event-" .. index, sessionId = "chunk-session",
        contextId = "chunk-context", timestamp = "2026-11-06T00:00:00Z",
        payload = { marker = "chunk-only-payload", sequence = index } }
    queue:Upsert(events[index])
end
assert(queue:Persist())
assert(storage:GetItem(queueKey).blocks == 3)
assert(not files["gamealgo_sdk_storage_v1.json"]:find("chunk-only-payload", 1, true),
    "events must not remain embedded in the identity/config snapshot")
local cloudFiles, cloudKeys = {}, {}
clientCloud = {
    Get = function(_, key, callbacks)
        callbacks.ok({ [key] = cloudFiles[key] and cjson.decode(cloudFiles[key]) or nil })
    end,
    Set = function(_, key, data, callbacks)
        cloudFiles[key] = cjson.encode(data)
        table.insert(cloudKeys, key)
        callbacks.ok()
    end,
}
storage:Flush()
assert(#cloudKeys == 4 and cloudKeys[4] == "gamealgo_sdk_storage_v1",
    "publish all chunks before their cloud directory")
local mainFile, beforeAppend = files["gamealgo_sdk_storage_v1.json"], writes
local added = { eventId = "chunk-event-251", sessionId = "chunk-session", contextId = "chunk-context" }
queue:Upsert(added)
assert(queue:Persist())
assert(writes == beforeAppend + 1, "append must write only the tail chunk")
assert(files["gamealgo_sdk_storage_v1.json"] == mainFile, "append must not rewrite the SDK snapshot")
cloudKeys = {}
storage:Flush()
assert(#cloudKeys == 1 and cloudKeys[1] == prefix .. "_3", "append must upload only the tail chunk")

local acknowledged = {}
for index = 1, 100 do table.insert(acknowledged, events[index]) end
local beforeAck = writes
queue:Remove(acknowledged)
assert(queue:Persist())
assert(writes == beforeAck + 1, "ACK must update only the affected chunk")
cloudKeys = {}
storage:Flush()
assert(#cloudKeys == 1 and cloudKeys[1] == prefix .. "_1")
local recovered = assert(MakerAutoStorage.New())
assert(#recovered:EventQueue(queueKey):Events() == 151, "ACKed entries must not reappear on cold start")

-- A partial inactive-bank write cannot destroy the last committed bank.
local tail = { eventId = "chunk-event-252", sessionId = "chunk-session", contextId = "chunk-context" }
queue:Upsert(tail)
failWriteName = prefix .. "_1_1.json"
assert(queue:Persist() == false)
recovered = assert(MakerAutoStorage.New())
assert(#recovered:EventQueue(queueKey):Events() == 151, "partial writes must preserve every earlier unacknowledged event")
failWriteName = nil
assert(queue:Persist())
assert(#assert(MakerAutoStorage.New()):EventQueue(queueKey):Events() == 152)

-- Failed cloud jobs stay dirty. Retrying must never republish an old mutable
-- object or upload the directory after a failed prerequisite chunk.
local normalSet = clientCloud.Set
local held = {}
clientCloud.Set = function(_, key, data, callbacks)
    table.insert(held, { key = key, data = data, callbacks = callbacks })
end
local cloudError
storage:Flush(function(error) cloudError = error end)
assert(#held == 1)
held[1].callbacks.error(503, "offline")
assert(cloudError == "offline")
held = {}
storage:Flush()
assert(#held == 1)
events[101].contextId = "updated-context"
queue:Upsert(events[101])
assert(queue:Persist())
storage:Flush()
assert(#held == 1, "cloud writes must remain serialized")
local firstJob = held[1]
cloudFiles[firstJob.key] = cjson.encode(firstJob.data)
firstJob.callbacks.ok()
assert(#held == 2, "changes during a request must drain after its ACK")
firstJob.callbacks.ok() -- duplicate completion must not advance the next job
assert(#held == 2)
local secondJob = held[2]
cloudFiles[secondJob.key] = cjson.encode(secondJob.data)
secondJob.callbacks.ok()
clientCloud.Set = normalSet

local tasks = {}
local scheduler = {
    Schedule = function(_, _, callback)
        local task = { callback = callback }
        table.insert(tasks, task)
        return task
    end,
    Cancel = function(_, task) task.cancelled = true end,
    IsAutomatic = function() return true end,
}
files = {}
local cloudRestored = assert(MakerAutoStorage.New({ scheduler = scheduler }))
assert(cloudRestored:IsReady())
local restoredEvents = cloudRestored:EventQueue(queueKey):Events()
assert(#restoredEvents == 152 and restoredEvents[1].eventId == "chunk-event-101")
assert(restoredEvents[1].contextId == "updated-context", "context binding must survive cloud recovery")
assert(restoredEvents[#restoredEvents].eventId == tail.eventId)
assert(#assert(MakerAutoStorage.New()):EventQueue(queueKey):Events() == 152,
    "cloud recovery must checkpoint chunks locally before ready")

-- A timeout reserves unread chunks rather than overwriting them with an empty
-- queue; late callbacks cannot mutate the already initialized runtime.
files, tasks = {}, {}
local normalGet, pendingReads = clientCloud.Get, {}
clientCloud.Get = function(self, key, callbacks)
    if key == "gamealgo_sdk_storage_v1" then normalGet(self, key, callbacks)
    else table.insert(pendingReads, { key = key, callbacks = callbacks }) end
end
local timedOut = assert(MakerAutoStorage.New({ scheduler = scheduler }))
assert(not timedOut:IsReady() and #pendingReads == 3)
tasks[#tasks].callback()
assert(timedOut:IsReady())
local timeoutQueue = timedOut:EventQueue(queueKey)
assert(#timeoutQueue:Events() == 0)
timeoutQueue:Upsert({ eventId = "during-cloud-timeout", sessionId = "new-session", contextId = "new-context" })
assert(timeoutQueue:Persist())
assert(timedOut:GetItem(queueKey).blocks == 4, "new data must not reuse unread chunks")
timedOut:Flush()
for _, pending in ipairs(pendingReads) do
    pending.callbacks.ok({ [pending.key] = cjson.decode(cloudFiles[pending.key]) })
end
assert(#timeoutQueue:Events() == 1, "late reads must not replace live state")
clientCloud.Get = normalGet
files = {}
assert(#assert(MakerAutoStorage.New({ scheduler = scheduler })):EventQueue(queueKey):Events() == 153,
    "a subsequent successful cloud recovery must retain old and new events")

-- Maker hosts without File still use the independent cloud chunks, with no
-- dependency on a successful local checkpoint or a full-queue fallback value.
local previousFile, previousRead, previousWrite = File, FILE_READ, FILE_WRITE
File, FILE_READ, FILE_WRITE = nil, nil, nil
local cloudOnly = assert(MakerAutoStorage.New({ scheduler = scheduler }))
local cloudOnlyQueue = cloudOnly:EventQueue(queueKey)
assert(#cloudOnlyQueue:Events() == 153)
cloudOnlyQueue:Upsert({ eventId = "cloud-only-tail", sessionId = "cloud-only-session" })
assert(cloudOnlyQueue:Persist() == false, "cloud sync must not claim local durability")
cloudOnly:Flush()
assert(#assert(MakerAutoStorage.New({ scheduler = scheduler })):EventQueue(queueKey):Events() == 154)
File, FILE_READ, FILE_WRITE = previousFile, previousRead, previousWrite
clientCloud = nil

-- Legacy JSONL remains the recovery source until every new chunk is durable.
files = {}
local legacy = assert(MakerAutoStorage.New())
local lines = {}
for index = 1, 620 do
    table.insert(lines, cjson.encode({ eventId = "legacy-" .. index, sessionId = "legacy-session",
        contextId = "legacy-context", timestamp = "2026-11-05T00:00:00Z" }))
end
legacy:SetItem(queueKey, table.concat(lines, "\n"))
local migration = legacy:EventQueue(queueKey)
failWriteName = prefix .. "_2_1.json"
assert(migration:Persist() == false)
assert(type(require("tests.support.PersistedSnapshot")(files).data[queueKey]) == "string")
assert(#assert(MakerAutoStorage.New()):EventQueue(queueKey):Events() == 620,
    "interrupted migration must preserve the full legacy queue")
failWriteName = nil
assert(migration:Persist())
assert(type(require("tests.support.PersistedSnapshot")(files).data[queueKey]) == "table")
local migratedEvents = assert(MakerAutoStorage.New()):EventQueue(queueKey):Events()
assert(#migratedEvents == 620 and migratedEvents[620].eventId == "legacy-620")
assert(migratedEvents[1].timestamp == "2026-11-05T00:00:00Z")

-- Legacy event IDs are not assumed unique: internal slots use object identity.
local duplicates = legacy:EventQueue("duplicate:events:jsonl")
local first = { eventId = "duplicate-id", sessionId = "duplicate-session" }
local second = { eventId = "duplicate-id", sessionId = "duplicate-session" }
duplicates:Upsert(first); duplicates:Upsert(second)
assert(#duplicates:Events() == 2)
duplicates:Remove({ first })
assert(duplicates:Persist())
assert(#assert(MakerAutoStorage.New()):EventQueue("duplicate:events:jsonl"):Events() == 1)

-- A torn directory must not make already committed chunk files undiscoverable.
-- Exercise both root banks, including retrying after an interrupted write.
files = {}
local directoryStorage = assert(MakerAutoStorage.New())
local directoryQueue = directoryStorage:EventQueue("directory-fault:events:jsonl")
for index = 1, 100 do
    directoryQueue:Upsert({ eventId = "directory-" .. index, sessionId = "directory-session" })
end
assert(directoryQueue:Persist())
local last = 100
for _, nextCount in ipairs({ 101, 201 }) do
    for index = last + 1, nextCount do
        directoryQueue:Upsert({ eventId = "directory-" .. index, sessionId = "directory-session" })
    end
    local _, committedFile = require("tests.support.PersistedSnapshot")(files)
    failWriteName = committedFile == "gamealgo_sdk_storage_v1.json"
        and "gamealgo_sdk_storage_v1.backup.json" or "gamealgo_sdk_storage_v1.json"
    assert(directoryQueue:Persist() == false)
    failWriteName = nil
    local recovered = assert(MakerAutoStorage.New()):EventQueue("directory-fault:events:jsonl"):Events()
    assert(#recovered == last, "a torn directory must retain every previously committed event")
    assert(directoryQueue:Persist())
    assert(#assert(MakerAutoStorage.New()):EventQueue("directory-fault:events:jsonl"):Events() == nextCount)
    last = nextCount
end

print("Maker automatic storage first-run tests passed")
