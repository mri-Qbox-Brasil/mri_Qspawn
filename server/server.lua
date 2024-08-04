GlobalState:set('firstLogin', GlobalState['firstLogin'] or {})
local QBCore = exports['qb-core']:GetCoreObject()
RegisterNetEvent('mri_Qspawn:server:firstSpawn', function()
    local firstLogin = GlobalState['firstLogin']
    local Player = QBCore.Functions.GetPlayer(source)
    firstLogin[tostring(Player.PlayerData.citizenid)] = true
    GlobalState:set('firstLogin', firstLogin, true)
end)