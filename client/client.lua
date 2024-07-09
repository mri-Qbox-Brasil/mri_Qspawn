local function DoSpawn()
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
    TriggerEvent('QBCore:Client:OnPlayerLoaded')
    TriggerServerEvent('qb-houses:server:SetInsideMeta', 0, false)
    TriggerServerEvent('qb-apartments:server:SetInsideMeta', 0, 0, false)
    SetPlayerInvincible(cache.ped, false)
    FreezeEntityPosition(cache.ped, false)
end

local function LoadingSpinner(textToDisplay)
    AddTextEntry("CUSTOMLOADSTR", textToDisplay)
    BeginTextCommandBusyspinnerOn("CUSTOMLOADSTR")
    EndTextCommandBusyspinnerOn(4)
end

local function PointSelect(args)
    local pos = args.pos
    LoadingSpinner("Carregando...")

    RequestCollisionAtCoord(pos.x, pos.y, pos.z)
    SetPlayerInvincible(cache.ped, true)
    SetEntityCoordsNoOffset(cache.ped, pos.x, pos.y, pos.z, false, false, false, true)
    FreezeEntityPosition(cache.ped, true)
    SetEntityHeading(cache.ped, pos.a)
    ClearPedTasksImmediately(cache.ped)
    ClearPlayerWantedLevel(PlayerId())

    local time = GetGameTimer()
    while (not HasCollisionLoadedAroundEntity(cache.ped) and (GetGameTimer() - time) < cfg.Timeout) do
        Wait(100)
    end

    SwitchInPlayer(cache.ped)
    time = GetGameTimer()
    while (IsPlayerSwitchInProgress() and (GetGameTimer() - time) < cfg.Timeout) do
        Wait(100)
    end

    BusyspinnerOff()
    lib.showContext('spawnplayer')
end

local function CanChooseSpawn(pos)
    local badlocations = {
        [vector3(0, 0, 0)] = true,
        [vector4(0, 0, 0, 0)] = true
    }
    return not badlocations[pos]
end

local opt = {{
    title = cfg.LastLocation.Title,
    icon = cfg.LastLocation.Icon,
    onSelect = PointSelect,
    args = {
        pos = QBX.PlayerData.position
    }
}}

local function Init()
    if cfg.Locations and #cfg.Locations > 0 then
        for k, v in pairs(cfg.Locations) do
            table.insert(opt, {
                title = k,
                icon = v.Icon,
                description = v.Description,
                disabled = not CanChooseSpawn(v.Spawn),
                onSelect = PointSelect,
                args = {
                    pos = v.Spawn
                }
            })
        end
    end

    lib.registerContext({
        id = 'spawnselector',
        title = cfg.MenuTitle,
        canClose = false,
        options = opt
    })

    lib.registerContext({
        id = 'spawnplayer',
        title = cfg.MenuTitle,
        canClose = false,
        menu = 'spawnselector',
        options = {{
            title = 'Escolher aqui',
            icon = 'fa-solid fa-location-dot',
            onSelect = DoSpawn
        }},
        onBack = function()
            SwitchToMultiFirstpart(cache.ped, 0, 1)
        end
    })

    if cfg.Debug then
        RegisterCommand('choose', function()
            exports[GetCurrentResourceName()]:chooseSpawn()
        end, false)
    end
end

exports('chooseSpawn', function()
    SwitchToMultiFirstpart(cache.ped, 0, 1)
    if cfg.Locations and #cfg.Locations > 0 and cfg.AlwaysChooseSpawn then
        lib.showContext('spawnselector')
    else
        DoSpawn()
    end
end)

Init()