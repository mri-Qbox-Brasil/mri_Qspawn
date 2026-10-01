-- Spawn locations in mri_qspawn_locations; the panel addresses them by row id, not list index.

local spawns = {}
local loaded = promise.new()

local function rowToSpawn(r)
    return {
        id = r.id,
        label = r.label,
        coords = { x = r.x, y = r.y, z = r.z, w = r.heading },
        icon = r.icon,
        color = r.color,
        description = r.description,
    }
end

local function reload()
    local rows = MySQL.query.await('SELECT * FROM `mri_qspawn_locations` ORDER BY `sort_order`, `id`') or {}
    local list = {}
    for i = 1, #rows do list[i] = rowToSpawn(rows[i]) end
    spawns = list
end

local function isAdmin(source)
    return IsPlayerAceAllowed(source, 'mri_Qspawn.admin')
        or IsPlayerAceAllowed(source, 'command')
end

local function validSpawn(s)
    if type(s) ~= 'table' or type(s.label) ~= 'string' or s.label == '' then return false end
    local c = s.coords
    return type(c) == 'table' and tonumber(c.x) and tonumber(c.y) and tonumber(c.z) and true or false
end

CreateThread(function()
    StorageReady()
    reload()
    loaded:resolve(true)
end)

lib.callback.register('mri_Qspawn:server:getSpawns', function()
    Citizen.Await(loaded)
    return spawns
end)

lib.callback.register('mri_Qspawn:server:saveSpawn', function(source, payload)
    if not isAdmin(source) then return false, 'sem permissão' end
    if type(payload) ~= 'table' or not validSpawn(payload.spawn) then
        return false, 'payload inválido'
    end
    Citizen.Await(loaded)

    local s, id = payload.spawn, tonumber(payload.id)
    if id then
        local c = s.coords
        local changed = MySQL.update.await(
            'UPDATE `mri_qspawn_locations` SET `label` = ?, `x` = ?, `y` = ?, `z` = ?, `heading` = ?, `icon` = ?, `color` = ?, `description` = ? WHERE `id` = ?',
            { s.label, c.x, c.y, c.z, c.w or 0.0, s.icon, s.color, s.description, id })
        if changed == 0 then return false, 'local não encontrado' end
    else
        local order = (MySQL.scalar.await('SELECT COALESCE(MAX(`sort_order`), 0) FROM `mri_qspawn_locations`') or 0) + 1
        InsertLocationRow(s, order)
    end
    reload()
    return true, spawns
end)

lib.callback.register('mri_Qspawn:server:deleteSpawn', function(source, id)
    if not isAdmin(source) then return false, 'sem permissão' end
    id = tonumber(id)
    if not id then return false, 'id inválido' end
    Citizen.Await(loaded)
    local removed = MySQL.update.await('DELETE FROM `mri_qspawn_locations` WHERE `id` = ?', { id })
    if removed == 0 then return false, 'local não encontrado' end
    reload()
    return true, spawns
end)

lib.callback.register('mri_Qspawn:server:isAdmin', function(source)
    return isAdmin(source)
end)
