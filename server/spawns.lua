-- Carrega/persiste a lista de spawns em data/spawns.json. Em runtime mantemos
-- uma cópia em memória; toda escrita atualiza o arquivo via SaveResourceFile.

local SPAWNS_FILE = 'data/spawns.json'
local spawns = {}

local function loadFromDisk()
    local raw = LoadResourceFile(GetCurrentResourceName(), SPAWNS_FILE)
    if not raw or raw == '' then
        spawns = {}
        return
    end
    local ok, parsed = pcall(json.decode, raw)
    if not ok or type(parsed) ~= 'table' then
        -- Paridade com config.lua: loga em vez de zerar silenciosamente todos os
        -- spawns num JSON corrompido (facilita diagnóstico da perda).
        print(('[mri_Qspawn] AVISO: %s corrompido — usando lista vazia.'):format(SPAWNS_FILE))
        spawns = {}
        return
    end
    spawns = parsed
end

local function saveToDisk()
    local ok = SaveResourceFile(GetCurrentResourceName(), SPAWNS_FILE, json.encode(spawns, { indent = true }), -1)
    if not ok then
        print('[mri_Qspawn] ERRO: falha ao escrever ' .. SPAWNS_FILE)
    end
    return ok
end

local function isAdmin(source)
    return IsPlayerAceAllowed(source, 'mri_Qspawn.admin')
        or IsPlayerAceAllowed(source, 'command')
end

loadFromDisk()

lib.callback.register('mri_Qspawn:server:getSpawns', function()
    return spawns
end)

lib.callback.register('mri_Qspawn:server:saveSpawn', function(source, payload)
    if not isAdmin(source) then return false, 'sem permissão' end
    if type(payload) ~= 'table' or type(payload.spawn) ~= 'table' then
        return false, 'payload inválido'
    end
    local index = tonumber(payload.index)
    if index and spawns[index] then
        spawns[index] = payload.spawn
    else
        spawns[#spawns + 1] = payload.spawn
    end
    return saveToDisk(), spawns
end)

lib.callback.register('mri_Qspawn:server:deleteSpawn', function(source, index)
    if not isAdmin(source) then return false, 'sem permissão' end
    index = tonumber(index)
    if not index or not spawns[index] then return false, 'índice inválido' end
    table.remove(spawns, index)
    return saveToDisk(), spawns
end)

lib.callback.register('mri_Qspawn:server:isAdmin', function(source)
    return isAdmin(source)
end)
