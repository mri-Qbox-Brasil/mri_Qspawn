-- config persistido em data/config.json (gerenciado por server/config.lua).
-- Le sempre via GetSpawnConfig() pra pegar mutacoes em runtime (admin salvou
-- na UI). Cache local seria stale.

-- #RRGGBB ou #RRGGBBAA. O alpha e aceito e repassado; quem ignora e o
-- hexToHslVar da NUI (theming HSL), nao a validacao. Lua nao tem alternancia
-- em pattern, entao sao dois matches — %x?%x? aceitaria 7 digitos.
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

-- Registra o painel admin do mri_Qspawn como plugin do mri_Qadmin via export.
-- Se Qadmin nao tiver rodando no server, o pcall protege e o painel continua
-- acessivel via /adminspawn standalone normalmente. Manifest shape espelha
-- web/src/plugin/types.ts (drift control manual).
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

-- Qadmin inicia/reinicia → re-registra automaticamente
AddEventHandler('onServerResourceStart', function(resourceName)
    if resourceName == 'mri_Qadmin' then doRegister() end
end)

-- Plugin inicia com Qadmin já rodando → registra imediatamente
CreateThread(function()
    Wait(0)
    doRegister()
end)

-- Tabela local de controle de primeiro-spawn (selectOnFirstSpawn). Substitui
-- GlobalState para evitar race read-modify-write quando dois jogadores spawnam
-- simultaneamente. Persiste apenas em memória: intencional, reiniciar o recurso
-- reseta o controle (comportamento equivalente ao anterior com GlobalState).
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
    -- ps-housing é opcional: sem ele não há casas — sai cedo pra não chamar
    -- export inexistente nem consultar a tabela `properties` ausente.
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
            -- getMainDoor pode retornar nil e door.doors pode ser nil: protege a
            -- cadeia de coords com parênteses e só adiciona se resolveu coords.
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

-- Aviso de conflito: mri_Qspawn SUBSTITUI o qbx_spawn (mesmos callbacks/evento).
-- Se os dois rodarem juntos, o ox_lib registra handlers duplicados e as respostas
-- colidem (query dupla, alreadySpawned/spawn ambíguos).
CreateThread(function()
    if GetResourceState('qbx_spawn') == 'started' then
        print('[mri_Qspawn] ERRO: qbx_spawn está ATIVO — remova-o; os callbacks vão colidir com mri_Qspawn.')
    end
end)

