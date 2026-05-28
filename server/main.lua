-- config persistido em data/config.json (gerenciado por server/config.lua).
-- Le sempre via GetSpawnConfig() pra pegar mutacoes em runtime (admin salvou
-- na UI). Cache local seria stale.

local HEX_PATTERN = '^#%x%x%x%x%x%x$'

local function isValidHex(value)
    return type(value) == 'string' and value:match(HEX_PATTERN) ~= nil
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

-- Registra o painel admin do mri_Qspawn como plugin do mri_Qadmin via export.
-- Se Qadmin nao tiver rodando no server, o pcall protege e o painel continua
-- acessivel via /adminspawn standalone normalmente. Manifest shape espelha
-- web/src/plugin/types.ts (drift control manual).
local function registerPlugin()
    if GetResourceState('mri_Qadmin') ~= 'started' then return end
    local ok, result = pcall(function()
        return exports['mri_Qadmin']:RegisterPlugin({
            id = 'spawns',
            label = 'Spawns',
            icon = 'map-pin',
            resource = 'mri_Qspawn',
            htmlPath = 'html/index.html',
            requiredPerms = { 'mri_Qspawn.admin', 'command' },
            description = 'CRUD de spawns iniciais do servidor',
        })
    end)
    if not ok or result == false then
        print(('[mri_Qspawn] Falha ao registrar plugin no mri_Qadmin: %s'):format(tostring(result)))
    end
end

CreateThread(function()
    local deadline = GetGameTimer() + 10000
    while GetResourceState('mri_Qadmin') ~= 'started' and GetGameTimer() < deadline do
        Wait(200)
    end
    registerPlugin()
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == 'mri_Qadmin' then
        Wait(500) -- aguarda exports ficarem disponíveis
        registerPlugin()
    end
end)

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
    if not GetSpawnConfig().selectOnFirstSpawn then return false end
    local player = exports.qbx_core:GetPlayer(source)
    while not player do
        Wait(100)
        player = exports.qbx_core:GetPlayer(source)
    end
    local spawnedPlayers = GlobalState.SpawnedPlayers or {}
    return spawnedPlayers[player.PlayerData.citizenid]
end)

RegisterNetEvent('qbx_spawn:server:spawn', function()
    if not GetSpawnConfig().selectOnFirstSpawn then return end
    local player = exports.qbx_core:GetPlayer(source)
    while not player do
        Wait(100)
        player = exports.qbx_core:GetPlayer(source)
    end
    local spawnedPlayers = GlobalState.SpawnedPlayers or {}
    spawnedPlayers[player.PlayerData.citizenid] = true
    GlobalState:set('SpawnedPlayers', spawnedPlayers, true)
end)

