local opt = {
    {
        title = cfg.LastLocation.Title,
        icon = cfg.LastLocation.Icon,
        onSelect = function ()
            SetPlayerInvincible(cache.ped, true)
            SetEntityCoords(cache.ped, QBX.PlayerData.position.x, QBX.PlayerData.position.y, QBX.PlayerData.position.z)
            SetEntityHeading(cache.ped, QBX.PlayerData.position.a)
            while not HasCollisionLoadedAroundEntity(cache.ped) do Wait(0) end
            SetEntityCoords(cache.ped, QBX.PlayerData.position.x, QBX.PlayerData.position.y, QBX.PlayerData.position.z)
            SwitchInPlayer(cache.ped)
            while IsPlayerSwitchInProgress() do Wait(0) end
            lib.showContext('spawnplayer')
        end
    }
}

function CanChooseSpawn(pos)
    local badlocations = {
        [vector3(0,0,0)] = true,
        [vector4(0,0,0,0)] = true,
    }
    if badlocations[pos] then
        return false
    end
    return true
end

for k,v in pairs(cfg.Locations) do
    table.insert(opt,
        {
            title = k,
            icon = v.Icon,
            description = v.Description,
            disabled = not CanChooseSpawn(v.Spawn),
            onSelect = function ()
                SetPlayerInvincible(cache.ped, true)
                SetEntityCoords(cache.ped, v.Spawn)

                while not HasCollisionLoadedAroundEntity(cache.ped) do Wait(0) end
                SetEntityCoords(cache.ped, v.Spawn)

                SwitchToMultiSecondpart(cache.ped)
                while IsPlayerSwitchInProgress() do Wait(0) end
                lib.showContext('spawnplayer')
            end
        }
    )
end

lib.registerContext({
    id = 'spawnselector',
    title = 'Escolha uma localização',
    canClose = false,
    options = opt
})

lib.registerContext({
    id = 'spawnplayer',
    title = 'Escolha uma localização',
    canClose = false,
    menu = 'spawnselector',
    options = {
        {
            title = 'Escolher aqui',
            icon = 'fa-solid fa-location-dot',
            onSelect = function ()
                -- eventos após logar servidor
                TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
                TriggerEvent('QBCore:Client:OnPlayerLoaded')
                TriggerServerEvent('qb-houses:server:SetInsideMeta', 0, false)
                TriggerServerEvent('qb-apartments:server:SetInsideMeta', 0, 0, false)
                SetPlayerInvincible(cache.ped, false)
            end
        }
    },
    onBack = function ()
        SwitchToMultiFirstpart(cache.ped, 0, 2)
    end
})

exports('chooseSpawn',function ()
    SwitchToMultiFirstpart(cache.ped, 0, 2)
    lib.showContext('spawnselector')
end)

if cfg.Debug then
    RegisterCommand('choose',function ()
        exports[GetCurrentResourceName()]:chooseSpawn()
    end,false)
end
