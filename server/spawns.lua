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

-- The panel picks icon and color from lists; anything else a client sends is dropped.
local function validSpawn(s)
    if type(s) ~= 'table' or type(s.label) ~= 'string' or s.label == '' or #s.label > 48 then return false end
    local c = s.coords
    if type(c) ~= 'table' or not tonumber(c.x) or not tonumber(c.y) or not tonumber(c.z) then return false end
    if s.icon ~= nil and (type(s.icon) ~= 'string' or #s.icon > 32 or not s.icon:match('^[%l%d%-]+$')) then s.icon = nil end
    if s.color ~= nil and (type(s.color) ~= 'string' or not s.color:match('^#%x%x%x%x%x%x$')) then s.color = nil end
    if s.description ~= nil and (type(s.description) ~= 'string' or #s.description > 200) then s.description = nil end
    return true
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
    if not isAdmin(source) then return false, 'not allowed' end
    if type(payload) ~= 'table' or not validSpawn(payload.spawn) then
        return false, 'invalid payload'
    end
    Citizen.Await(loaded)

    local s, id = payload.spawn, tonumber(payload.id)
    if id then
        local c = s.coords
        local changed = MySQL.update.await(
            'UPDATE `mri_qspawn_locations` SET `label` = ?, `x` = ?, `y` = ?, `z` = ?, `heading` = ?, `icon` = ?, `color` = ?, `description` = ? WHERE `id` = ?',
            { s.label, c.x, c.y, c.z, c.w or 0.0, s.icon, s.color, s.description, id })
        if changed == 0 then return false, 'spot not found' end
    else
        local order = (MySQL.scalar.await('SELECT COALESCE(MAX(`sort_order`), 0) FROM `mri_qspawn_locations`') or 0) + 1
        id = InsertLocationRow(s, order)
    end
    reload()
    return true, spawns, id
end)

lib.callback.register('mri_Qspawn:server:deleteSpawn', function(source, id)
    if not isAdmin(source) then return false, 'not allowed' end
    id = tonumber(id)
    if not id then return false, 'invalid id' end
    Citizen.Await(loaded)
    local removed = MySQL.update.await('DELETE FROM `mri_qspawn_locations` WHERE `id` = ?', { id })
    if removed == 0 then return false, 'spot not found' end
    reload()
    return true, spawns
end)

lib.callback.register('mri_Qspawn:server:isAdmin', function(source)
    return isAdmin(source)
end)
