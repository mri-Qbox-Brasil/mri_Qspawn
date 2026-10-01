-- Spawn settings: data/config.default.json with the panel overrides from the database on top.

local defaults = ReadResourceJson('data/config.default.json')
if not defaults then
    error('[mri_Qspawn] data/config.default.json ausente ou corrompido: reinstale o resource.')
end

local overrides = {} -- block -> diff from default, as stored
local config = {}
local loaded = promise.new()

local function rebuild()
    config = ConfigMerge(json.decode(json.encode(defaults)), overrides)
end

local function isAdmin(source)
    return IsPlayerAceAllowed(source, 'mri_Qspawn.admin')
        or IsPlayerAceAllowed(source, 'command')
end

CreateThread(function()
    StorageReady()
    local rows = MySQL.query.await('SELECT `key`, `value` FROM `mri_qspawn_settings`') or {}
    for i = 1, #rows do
        local key = rows[i].key
        if defaults[key] ~= nil then
            local ok, value = pcall(json.decode, rows[i].value)
            -- Re-diff so fields removed from the default in an update are ignored.
            if ok then overrides[key] = ConfigDiff(defaults[key], value) end
        end
    end
    rebuild()
    loaded:resolve(true)
end)

function GetSpawnConfig()
    Citizen.Await(loaded)
    return config
end

lib.callback.register('mri_Qspawn:server:getConfig', function()
    return GetSpawnConfig()
end)

lib.callback.register('mri_Qspawn:server:saveConfig', function(source, payload)
    if not isAdmin(source) then return false, 'sem permissão' end
    if type(payload) ~= 'table' then return false, 'payload inválido' end
    Citizen.Await(loaded)

    -- A block equal to the default deletes its row.
    for key, value in pairs(payload) do
        if defaults[key] ~= nil then
            local d = ConfigDiff(defaults[key], value)
            SaveSettingRow(key, d)
            overrides[key] = d
        end
    end
    rebuild()

    TriggerClientEvent('mri_Qspawn:client:configChanged', -1, config)
    return true, config
end)
