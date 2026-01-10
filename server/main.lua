local config = require 'config.server'

-- Usar exatamente as mesmas funções do qbx_spawn
lib.callback.register('qbx_spawn:server:getLastLocation', function(source)
    local player = exports.qbx_core:GetPlayer(source)
    if not player then
        return nil, nil
    end
    
    local result = MySQL.single.await(
        'SELECT position FROM players WHERE citizenid = ?',
        {player.PlayerData.citizenid}
    )
    
    if not result or not result.position then
        return nil, nil
    end
    
    local position = json.decode(result.position)
    local propertyId = player.PlayerData.metadata.inside and
        player.PlayerData.metadata.inside.propertyId or nil
    
    return position, propertyId
end)

lib.callback.register('qbx_spawn:server:getHouses', function(source)
    local player = exports.qbx_core:GetPlayer(source)
    local houseData = {}

    local houses = MySQL.query.await(
                       'SELECT * FROM properties WHERE owner_citizenid = ?',
                       {player.PlayerData.citizenid})

    if not houses then return {} end

    for i = 1, #houses do
        local house = houses[i]
        if not house.apartment then
            local door = exports['ps-housing']:getMainDoor(house.property_id, 1, true)
            local coords = door.objCoords or door.coords or door.doors[1] and door.doors[1].coords or door.doors[1].objCoords
            houseData[#houseData + 1] = {label = house.street, coords = coords, propertyId = house.property_id}
        end
    end

    return houseData
end)

lib.callback.register('qbx_spawn:server:alreadySpawned', function(source)
    if not config.selectOnFirstSpawn then return false end
    local player = exports.qbx_core:GetPlayer(source)
    while not player do
        Wait(100)
        player = exports.qbx_core:GetPlayer(source)
    end
    local spawnedPlayers = GlobalState.SpawnedPlayers or {}
    return spawnedPlayers[player.PlayerData.citizenid]
end)

RegisterNetEvent('qbx_spawn:server:spawn', function()
    local player = exports.qbx_core:GetPlayer(source)
    while not player do
        Wait(100)
        player = exports.qbx_core:GetPlayer(source)
    end
    local spawnedPlayers = GlobalState.SpawnedPlayers or {}
    spawnedPlayers[player.PlayerData.citizenid] = true
    GlobalState:set('SpawnedPlayers', spawnedPlayers, true)
end)

