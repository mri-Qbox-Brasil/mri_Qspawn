-- Settings come from GetSpawnConfig() on every read: the admin may change them at runtime.

-- #RRGGBB or #RRGGBBAA (the NUI theme drops alpha); two patterns because %x?%x? would take 7 digits.
local HEX_RGB = '^#%x%x%x%x%x%x$'
local HEX_RGBA = '^#%x%x%x%x%x%x%x%x$'

local function isValidHex(value)
    if type(value) ~= 'string' then return false end
    return value:match(HEX_RGB) ~= nil or value:match(HEX_RGBA) ~= nil
end

local function resolveAccentColor()
    local convar = GetConvar('mri:color', '')
    if isValidHex(convar) then
        return convar
    end
    return '#00E699'
end

AddConvarChangeListener('mri:color', function(name)
    if name ~= 'mri:color' then return end
    local newColor = resolveAccentColor()
    TriggerClientEvent('mri_Qspawn:client:accentColorChanged', -1, newColor)
end)

AddConvarChangeListener('mri:backgroundColor', function(name)
    if name ~= 'mri:backgroundColor' then return end
    local newColor = GetConvar('mri:backgroundColor', '')
    TriggerClientEvent('mri_Qspawn:client:backgroundColorChanged', -1, newColor)
end)

-- mri_Qadmin plugin; without Qadmin the panel still opens with /adminspawn.
local function doRegister()
    if GetResourceState('mri_Qadmin') ~= 'started' then return end
    exports['mri_Qadmin']:RegisterPlugin({
        id = 'spawns',
        label = 'Spawns',
        icon = 'map-pin',
        resource = 'mri_Qspawn',
        htmlPath = 'html/index.html',
        requiredPerms = { 'mri_Qspawn.admin', 'command' },
        description = 'CRUD de spawns iniciais do servidor',
    })
end

-- Qadmin fires this when its registry accepts plugins; RegisterPlugin is idempotent by id.
AddEventHandler('mri_Qadmin:server:pluginsReady', doRegister)

AddEventHandler('onServerResourceStart', function(resourceName)
    if resourceName == 'mri_Qadmin' then doRegister() end
end)

CreateThread(function()
    Wait(0)
    doRegister()
end)

-- First-spawn control per citizenid (selectOnFirstSpawn), in memory on purpose: a restart resets it.
local spawnedPlayers = {}

local function waitForPlayer(source, timeoutMs)
    local player = exports.qbx_core:GetPlayer(source)
    local deadline = GetGameTimer() + (timeoutMs or 5000)
    while not player and GetGameTimer() < deadline do
        Wait(100)
        player = exports.qbx_core:GetPlayer(source)
    end
    return player
end

-- Same callbacks as qbx_spawn.
lib.callback.register('qbx_spawn:server:getLastLocation', function(source)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then
        return nil, nil
    end

    -- the position loaded at login: the database may already hold the selection spot from a save made before the spawn
    local loaded = player.PlayerData.position
    if not loaded then
        return nil, nil
    end

    local position = { x = loaded.x, y = loaded.y, z = loaded.z, w = loaded.w }
    local propertyId = player.PlayerData.metadata.inside and
        player.PlayerData.metadata.inside.property_id or nil

    return position, propertyId
end)

lib.callback.register('qbx_spawn:server:getHouses', function(source)
    -- ps-housing is optional: without it there are no houses nor a properties table.
    if GetResourceState('ps-housing') ~= 'started' then return {} end

    local player = exports.qbx_core:GetPlayer(source)
    if not player then return {} end

    local houseData = {}

    local houses = MySQL.query.await(
        'SELECT property_id, street, apartment FROM properties WHERE owner_citizenid = ?',
        {player.PlayerData.citizenid})

    if not houses then return {} end

    for i = 1, #houses do
        local house = houses[i]
        if not house.apartment then
            -- getMainDoor and door.doors may be nil; only houses with resolved coords go in.
            local door = exports['ps-housing']:getMainDoor(house.property_id, 1, true)
            local coords = door and (door.objCoords or door.coords
                or (door.doors and door.doors[1] and (door.doors[1].coords or door.doors[1].objCoords)))
            if coords then
                houseData[#houseData + 1] = {label = house.street, coords = coords, propertyId = house.property_id}
            end
        end
    end

    return houseData
end)

lib.callback.register('qbx_spawn:server:alreadySpawned', function(source)
    if not GetSpawnConfig().selectOnFirstSpawn then return false end
    local player = waitForPlayer(source)
    if not player then return false end
    return spawnedPlayers[player.PlayerData.citizenid] == true
end)

RegisterNetEvent('qbx_spawn:server:spawn', function()
    if not GetSpawnConfig().selectOnFirstSpawn then return end
    local player = waitForPlayer(source)
    if not player then return end
    spawnedPlayers[player.PlayerData.citizenid] = true
end)

-- Running qbx_spawn too makes the callbacks collide; GetResourceState says 'started' through our provide, so look for the real name.
CreateThread(function()
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name == 'qbx_spawn' and GetResourceState(name) == 'started' then
            print('[mri_Qspawn] ERRO: qbx_spawn está ATIVO, remova-o: os callbacks vão colidir com mri_Qspawn.')
            return
        end
    end
end)

