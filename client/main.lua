local Arrival = require 'client.arrival'
local spawns = {}

-- Panel settings, fetched from the server on first use and kept in sync by configChanged.
local config = {}
local configHydrated = false
local configLoading = false

local function ensureConfig()
    if configHydrated then return end
    -- A second caller waits for the first fetch instead of asking again.
    if configLoading then
        while not configHydrated do Wait(50) end
        return
    end
    configLoading = true
    local data = lib.callback.await('mri_Qspawn:server:getConfig', false)
    if type(data) == 'table' then
        for k, v in pairs(data) do config[k] = v end
    end
    configHydrated = true
    configLoading = false
end

-- Suite accent from the mri:color convar, kept apart from the panel settings.
local accentColor = GetConvar('mri:color', '#00E699')
local backgroundColor = GetConvar('mri:backgroundColor', '')

-- ox_lib /uiconfig look for the standalone NUI; nil without ox_lib.
local oxLibUiConfig = nil
local function fetchOxLibUiConfig()
    if GetResourceState('ox_lib') ~= 'started' then return end
    local ok, cfg = pcall(function() return lib.callback.await('ox_lib:getUiConfig', false) end)
    if ok then oxLibUiConfig = cfg end
end
-- On a thread: awaiting at file level delayed the NUI callbacks and nuiReady got a 404.
CreateThread(fetchOxLibUiConfig)

RegisterNetEvent('ox_lib:uiConfigChanged', function(cfg)
    oxLibUiConfig = cfg
    SendNUIMessage({ action = 'updateUiConfig', uiConfig = cfg })
end)

local function debug(...)
    if config.debug then print(...) end
end

-- Same clock and prefix as mri_Qmultichar, so the spawn time adds up from the character pick.
local function markTime(step)
    debug(('[tempo-spawn] %s t=%d'):format(step, GetGameTimer()))
end

CreateThread(function()
    ensureConfig()
end)

local function getTranslatedLabel(label)
    if not label then return label end
    if label == 'last_location' then
        return locale('last_location') or label
    end
    return label
end

local isNuiOpen = false
local previewCam = nil
local selectedSpawn = nil
local hasJsSignaledReady = false -- set once the NUI acked the open message
local jsHasMounted = false -- nuiReady on mount: nothing is sent before the NUI listens

-- First-person selection camera; switching spots is a quick blink (fade out, move, fade in).
local createCam, startCameraLoop, requestShowLocation, startEmerge
local resolveGroundZ, teleportPed, setupShot, sendOpenMessage
local cam = {
    mode = nil,        -- 'presence'
    target = nil,      -- current spot { x, y, z = ground, w }
    eyeZ = 0.0,        -- ground + presence.eyeHeight
    busy = false,      -- true while blinking to another spot
    pendingCoords = nil,
}

-- Accepts vec3/vec4, {x,y,z,w} and {[1],[2],[3],[4]}.
local function getCoordsValues(coords)
    if not coords then return nil, nil, nil, nil end

    local x, y, z, w

    if coords.x and coords.y and coords.z then
        x = tonumber(coords.x) or coords.x
        y = tonumber(coords.y) or coords.y
        z = tonumber(coords.z) or coords.z
        w = coords.w and (tonumber(coords.w) or coords.w) or nil
        return x, y, z, w
    end

    if coords[1] and coords[2] and coords[3] then
        x = tonumber(coords[1]) or coords[1]
        y = tonumber(coords[2]) or coords[2]
        z = tonumber(coords[3]) or coords[3]
        w = coords[4] and (tonumber(coords[4]) or coords[4]) or nil
        return x, y, z, w
    end

    return nil, nil, nil, nil
end

-- The render loop drives the camera from the next frame, so the start params only need to exist.
createCam = function(cx, cy, cz)
    -- The qbx_core multichar leaves its preview cam on; without this reset ours never renders.
    RenderScriptCams(false, false, 0, true, true)
    DestroyAllCams(true)

    previewCam = CreateCamWithParams(
        'DEFAULT_SCRIPTED_CAMERA',
        cx, cy, cz + 100.0,
        0.0, 0.0, 0.0,
        55.0,
        false,
        0
    )

    if config.postfx and config.postfx.dof then
        SetCamUseShallowDofMode(previewCam, true)
        SetCamNearDof(previewCam, 6.0)
        SetCamFarDof(previewCam, 48.0)
        SetCamDofStrength(previewCam, 1.0)
    end

    SetCamActive(previewCam, true)
    RenderScriptCams(true, false, 0, true, true)
end

---@param blendMs number|nil blend back to the game camera; 0 when another script cam takes over
local function stopCamera(blendMs)
    if previewCam and DoesCamExist(previewCam) then
        SetCamActive(previewCam, false)
        RenderScriptCams(false, true, blendMs or 1000, true, true)
        DestroyCam(previewCam, true)
        previewCam = nil
    end

    ClearFocus()
end

local function hideGameHudWhileOpen()
    CreateThread(function()
        while isNuiOpen and DoesCamExist(previewCam) do
            HideHudAndRadarThisFrame()
            Wait(0)
        end
    end)
end

local function managePlayer()
    FreezeEntityPosition(cache.ped, true)
    SetEntityInvincible(cache.ped, true)
    SetEntityVisible(cache.ped, false, false)
end

-- Starts the MLO load without waiting, so it streams during the scene wait instead of after it.
local function beginInteriorLoad(x, y, z)
    local interior = GetInteriorAtCoords(x, y, z)
    if interior == 0 then return 0 end
    LoadInterior(interior)
    return interior
end

-- Waits for the MLO with a cap; streamAround already asked for it.
local function waitInteriorReady(interior, timeoutMs)
    if interior == 0 then return false end
    local deadline = GetGameTimer() + (timeoutMs or 1200)
    while not IsInteriorReady(interior) and GetGameTimer() < deadline do
        Wait(10)
    end
    return IsInteriorReady(interior)
end

-- Ground z without moving the ped; inside an MLO the saved z wins. Call after streamAround.
resolveGroundZ = function(x, y, z)
    -- An interior being present decides, not loaded: the outside ground would drop the ped on the street below.
    local interior = beginInteriorLoad(x, y, z)
    if interior ~= 0 then
        waitInteriorReady(interior)
        -- Saved z is the ped root (~1 m above the feet): probe this floor from it, never from above.
        local onFloor, floorZ = GetGroundZFor_3dCoord(x, y, z + 0.5, false)
        if onFloor and floorZ > z - 3.0 then return floorZ end
        return z
    end
    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 5.0, false)
    if found and groundZ > 0.0 then return groundZ end
    return z
end

-- Frozen, invincible ped at the spot; hidden during the selection (the camera is its eyes).
teleportPed = function(x, y, z, w, visible)
    SetEntityCoords(cache.ped, x, y, z, false, false, false, false)
    SetEntityHeading(cache.ped, w or 0.0)
    FreezeEntityPosition(cache.ped, true)
    SetEntityVisible(cache.ped, visible ~= false, false)
    SetEntityInvincible(cache.ped, true)
end

-- Loads the scene around the spot (focus, collision, NewLoadScene) before showing it, with a cap.
local function streamAround(x, y, z, maxMs)
    SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)
    RequestCollisionAtCoord(x, y, z)
    NewLoadSceneStartSphere(x, y, z, 80.0, 0)
    -- Asks for the MLO now so it streams during the wait (saves ~3 s for players who log off indoors).
    beginInteriorLoad(x, y, z)
    local deadline = GetGameTimer() + (maxMs or 1500)
    while not IsNewLoadSceneLoaded() and GetGameTimer() < deadline do
        RequestCollisionAtCoord(x, y, z)
        Wait(0)
    end
    NewLoadSceneStop()
end

-- Waits for collision under the ped so it does not fall on the fade-in frame.
local function waitPedCollision(maxMs)
    local deadline = GetGameTimer() + (maxMs or 500)
    while not HasCollisionLoadedAroundEntity(cache.ped) and GetGameTimer() < deadline do
        local pc = GetEntityCoords(cache.ped)
        RequestCollisionAtCoord(pc.x, pc.y, pc.z)
        Wait(0)
    end
end

-- Native frontend sounds, gated by config.sound.enabled.
local UI_SOUNDS = {
    blink   = { name = 'NAV_UP_DOWN', set = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    confirm = { name = 'SELECT',      set = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
}
local function playUiSound(kind)
    if not (config.sound and config.sound.enabled ~= false) then return end
    local s = UI_SOUNDS[kind]
    if s then PlaySoundFrontend(-1, s.name, s.set, true) end
end

-- hideHud state bag: any HUD that listens to it hides during the selection.
local function setCustomHudHidden(hide)
    LocalPlayer.state:set('hideHud', hide == true, true)
end

local function serializeCoords(coords)
    if not coords then return nil end
    if type(coords) == 'string' then
        local ok, parsed = pcall(json.decode, coords)
        if ok and parsed then return serializeCoords(parsed) end
        return nil
    end
    local x, y, z, w = getCoordsValues(coords)
    if not (x and y and z) then return nil end
    return { x = x, y = y, z = z, w = w }
end

local function serializeSpawns(spawnsToSerialize)
    if not spawnsToSerialize then return {} end
    local serialized = {}
    for i = 1, #spawnsToSerialize do
        local spawn = spawnsToSerialize[i]
        local coords = spawn and serializeCoords(spawn.coords)
        if coords then
            serialized[#serialized + 1] = {
                label = getTranslatedLabel(spawn.label),
                coords = coords,
                icon = spawn.icon,
                color = spawn.color,
                isLast = spawn.label == 'last_location',
                propertyId = spawn.propertyId,
                first_time = spawn.first_time,
                key = spawn.key
            }
        end
    end
    return serialized
end

local function openSpawnUI()
    if isNuiOpen then
        print('[mri_Qspawn] AVISO: Tentativa de abrir UI quando já está aberta!')
        return
    end

    if #spawns == 0 then
        print('[mri_Qspawn] ERRO: Nenhum spawn disponível!')
        return
    end

    ensureConfig()

    isNuiOpen = true
    hasJsSignaledReady = false

    managePlayer()
    setCustomHudHidden(true)

    local fx, fy, fz, fw = getCoordsValues(spawns[1].coords)
    if not (fx and fy and fz) then
        local pedPos = GetEntityCoords(cache.ped)
        fx, fy, fz, fw = pedPos.x, pedPos.y, pedPos.z, GetEntityHeading(cache.ped)
    end

    -- Coming from the multichar the screen is already black; fading again costs 150 ms.
    if not IsScreenFadedOut() then
        DoScreenFadeOut(150)
        while not IsScreenFadedOut() do Wait(0) end
    end

    streamAround(fx, fy, fz, (config.blink and config.blink.stream) or 1500)
    markTime('cena carregada')

    -- The ped waits hidden at the spot, so confirming spawns it in the right place.
    fz = resolveGroundZ(fx, fy, fz)
    teleportPed(fx, fy, fz, fw, false)
    waitPedCollision(500)

    cam.pendingCoords = nil
    cam.busy = false
    setupShot(fx, fy, fz, fw)
    cam.mode = 'presence'

    createCam(fx, fy, fz)
    hideGameHudWhileOpen()
    startCameraLoop()

    -- Hold so the camera renders its first frame before the fade-in.
    Wait(200)
    DoScreenFadeIn(400)
    while IsScreenFadingIn() do Wait(0) end
    markTime('selecao visivel')

    SetNuiFocus(true, true)

    if jsHasMounted then
        sendOpenMessage()
    else
        -- First load only: React is not mounted yet, so send on nuiReady or after a timeout.
        CreateThread(function()
            local start = GetGameTimer()
            while isNuiOpen and not jsHasMounted do
                if GetGameTimer() - start > 8000 then
                    debug('[mri_Qspawn] React demorou pra montar; forçando abertura via fallback.')
                    sendOpenMessage()
                    break
                end
                Wait(100)
            end
        end)
    end
end

-- Called by nuiReady and by the 8 s fallback; only the nuiReady ack stops a resend.
sendOpenMessage = function()
    if not isNuiOpen or hasJsSignaledReady then return end

    SendNUIMessage({
        action = 'open',
        spawns = serializeSpawns(spawns),
        accentColor = accentColor,
        backgroundColor = backgroundColor,
        uiConfig = oxLibUiConfig,
        locale = GetConvar('ox:locale', 'en'),
        ui = {
            letterbox = config.letterbox,
            vignette = not (config.postfx and config.postfx.vignette == false),
            grain = not (config.postfx and config.postfx.grain == false),
        },
    })

    markTime('ui aberta')

    if #spawns > 0 then
        selectedSpawn = spawns[1]
    end
end

-- Camera engine: first-person presence and the blink between spots.

-- `gz` is the resolved ground z.
setupShot = function(tx, ty, gz, w)
    cam.target = { x = tx, y = ty, z = gz, w = w }
    cam.eyeZ = gz + config.presence.eyeHeight
end

local function updatePresence()
    local p = config.presence
    local t = cam.target
    if not t then return end
    local sway = p.sway
    local now = GetGameTimer() / 1000.0

    local swX  = math.sin(now * 0.7)  * 0.010 * sway
    local swY  = math.cos(now * 0.9)  * 0.010 * sway
    local bobZ = math.sin(now * 1.1)  * 0.012 * sway
    local yawS = math.sin(now * 0.5)  * 0.35  * sway -- degrees
    local pitS = math.sin(now * 0.65) * 0.25  * sway -- degrees

    SetCamCoord(previewCam, t.x + swX, t.y + swY, cam.eyeZ + bobZ)
    SetCamRot(previewCam, p.pitch + pitS, 0.0, (t.w or 0.0) + yawS, 0)
    SetCamFov(previewCam, p.fov)
end

-- Tells the NUI which spot the camera really shows, so the name changes with the image.
local function notifyShown(index)
    SendNUIMessage({ action = 'locationShown', index = index })
end

---@param index number spot index in the NUI (0-based)
requestShowLocation = function(coords, index)
    if cam.mode ~= 'presence' then return end
    local x, y, z, w = getCoordsValues(coords)
    if not (x and y and z) then return end
    -- While blinking the latest request replaces the pending one; the same-spot check runs when it plays.
    if cam.busy then cam.pendingCoords = { coords = coords, index = index }; return end
    if cam.target then
        local dx, dy, dz = cam.target.x - x, cam.target.y - y, cam.target.z - z
        if dx * dx + dy * dy + dz * dz < 1.0 then notifyShown(index); return end
    end

    cam.busy = true
    playUiSound('blink')
    CreateThread(function()
        local b = config.blink
        DoScreenFadeOut(b.out)
        while not IsScreenFadedOut() do Wait(0) end

        -- Load the destination while the screen is black, so the map never shows building up.
        streamAround(x, y, z, b.stream)
        if not isNuiOpen or not previewCam or not DoesCamExist(previewCam) then
            cam.busy = false; return
        end

        local gz = resolveGroundZ(x, y, z)
        teleportPed(x, y, gz, w, false)
        waitPedCollision(500)
        setupShot(x, y, gz, w)
        updatePresence() -- camera in place on the first frame

        notifyShown(index)
        DoScreenFadeIn(b['in'])
        cam.busy = false

        local pending = cam.pendingCoords
        cam.pendingCoords = nil
        if pending then requestShowLocation(pending.coords, pending.index) end
    end)
end

local function easeInOut(p)
    if p < 0.5 then return 4 * p * p * p end
    return 1 - math.pow(-2 * p + 2, 3) / 2
end

-- Shows the character: with the arrival on it materializes and the pulse leaves its feet.
---@param feet vector3
local function arrive(feet)
    if not config.arrival.enabled then
        SetEntityVisible(cache.ped, true, false)
        return
    end
    Arrival.materialize(cache.ped)
    Arrival.pulse(feet, accentColor:sub(1, 7), config.sound.enabled ~= false)
end

-- Confirm: the camera pulls back from the eyes to third person, then blends to the game camera.
local function updateEmerge()
    local e = config.emerge
    local p = config.presence
    local t = cam.target
    if not t then return end
    local prog = math.min((GetGameTimer() - cam.emergeStart) / e.duration, 1.0)
    local tt = easeInOut(prog)

    -- Show the ped only once the lens left the head (~0.45 m), or the first frame shows its inside.
    if not cam.emergeRevealed and tt * e.distance > 0.45 then
        cam.emergeRevealed = true
        arrive(vector3(t.x, t.y, t.z))
    end

    local h = math.rad(t.w or 0.0)
    local fwdX, fwdY = -math.sin(h), math.cos(h)
    local ex = t.x - fwdX * e.distance
    local ey = t.y - fwdY * e.distance
    local ez = cam.eyeZ + e.height

    SetCamCoord(previewCam,
        t.x + (ex - t.x) * tt,
        t.y + (ey - t.y) * tt,
        cam.eyeZ + (ez - cam.eyeZ) * tt)
    SetCamRot(previewCam,
        p.pitch + (e.pitch - p.pitch) * tt,
        0.0, t.w or 0.0, 0)
    SetCamFov(previewCam, p.fov)
end

startCameraLoop = function()
    CreateThread(function()
        while isNuiOpen and previewCam and DoesCamExist(previewCam) do
            if cam.mode == 'presence' then updatePresence()
            elseif cam.mode == 'emerge' then updateEmerge() end
            if config.postfx and config.postfx.dof then SetUseHiDof() end
            Wait(0)
        end
    end)
end

RegisterNUICallback('getSpawns', function(_, cb)
    cb({ success = true, spawns = serializeSpawns(spawns) })
end)

RegisterNUICallback('selectSpawn', function(data, cb)
    if type(data.index) ~= 'number' then
        cb({ success = false, message = 'invalid index' })
        return
    end
    local spawnIndex = data.index + 1 -- the NUI index is 0-based
    if spawnIndex < 1 or spawnIndex > #spawns then
        cb({ success = false, message = 'invalid spawn' })
        return
    end

    local spawnData = spawns[spawnIndex]
    if not spawnData or not spawnData.coords then
        cb({ success = false, message = 'spawn without coords' })
        return
    end

    selectedSpawn = spawnData

    debug(string.format('[mri_Qspawn] Spawn selecionado: %s (índice %d)', spawnData.label or 'sem label', spawnIndex))

    requestShowLocation(spawnData.coords, data.index)
    cb({ success = true })
end)

-- ps-housing builds properties on OnPlayerLoaded; entering before initialisedProperties breaks its EnterShell.
local housingReady = LocalPlayer.state.isLoggedIn == true
AddEventHandler('ps-housing:client:initialisedProperties', function()
    housingReady = true
end)

-- No 'spawn' flag: ps-housing enters through PlayerEnter (bucket and inside metadata), like the door.
local function enterProperty(spawnInfo)
    if GetResourceState('ps-housing') ~= 'started' then return end
    local deadline = GetGameTimer() + 10000
    while not housingReady and GetGameTimer() < deadline do Wait(50) end
    if not housingReady then
        print('[mri_Qspawn] AVISO: ps-housing nao carregou os imoveis; entrada no imovel cancelada.')
        return
    end
    -- Bucket 0 first: ps-housing moves the player to the house bucket (the MLO lives in 0).
    if GetResourceState('mri_Qmultichar'):find('start') then
        TriggerServerEvent('mri_Qmultichar:server:setBucket', 0)
    end
    if spawnInfo.propertyId then
        TriggerServerEvent('ps-housing:server:enterProperty', tostring(spawnInfo.propertyId))
    else
        -- New character: ps-housing creates the starter apartment and puts the player inside.
        TriggerServerEvent('ps-housing:server:createNewApartment', spawnInfo.apartment)
    end
end

-- Player load events; run while the ped is hidden so the appearance reapply stays out of sight.
local function triggerSpawnLoad(spawnInfo)
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
    TriggerEvent('QBCore:Client:OnPlayerLoaded')
    if spawnInfo.propertyId or spawnInfo.apartment then
        enterProperty(spawnInfo)
    end
end

-- Housing takes over camera and teleport, so these spawns fade instead of the emerge.
local function spawnEntersProperty(spawnInfo)
    return spawnInfo.propertyId ~= nil or spawnInfo.apartment ~= nil
end

local function finishSpawn(insideProperty)
    -- Inside a property the bucket is the house one; back to 0 would leave the instance.
    if not insideProperty and GetResourceState('mri_Qmultichar'):find('start') then
        TriggerServerEvent('mri_Qmultichar:server:setBucket', 0)
    end
    TriggerServerEvent('qbx_spawn:server:spawn')
    markTime('controle entregue')
    debug('[mri_Qspawn] Spawn completado')
end

startEmerge = function(spawnData)
    CreateThread(function()
        -- Wait for a running blink to finish.
        local deadline = GetGameTimer() + 6000
        while isNuiOpen and cam.busy and GetGameTimer() < deadline do Wait(50) end
        if not isNuiOpen or not previewCam or not DoesCamExist(previewCam) then return end

        local e = config.emerge

        -- Close the NUI; isNuiOpen stays true so the render and hide-HUD loops keep running.
        selectedSpawn = nil
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'close' })

        if spawnEntersProperty(spawnData) then
            local fade = config.confirm.fade
            DoScreenFadeOut(fade)
            while not IsScreenFadedOut() do Wait(0) end
            cam.mode = nil
            isNuiOpen = false
            stopCamera()
            FreezeEntityPosition(cache.ped, false)
            SetEntityVisible(cache.ped, true, false)
            SetEntityInvincible(cache.ped, false)
            setCustomHudHidden(false)
            triggerSpawnLoad(spawnData)
            Wait(e.settle)
            DoScreenFadeIn(fade)
            Wait(300)
            finishSpawn(true)
            return
        end

        -- 1. Load with the ped hidden.
        triggerSpawnLoad(spawnData)
        Wait(e.settle)
        if not previewCam or not DoesCamExist(previewCam) then isNuiOpen = false; return end

        -- 2. Put the ped back on the spot (OnPlayerLoaded may move it), still hidden.
        teleportPed(cam.target.x, cam.target.y, cam.target.z, cam.target.w, false)
        SetEntityInvincible(cache.ped, false)

        -- 3. Pull the camera out to third person; updateEmerge shows the ped midway.
        cam.emergeRevealed = false
        cam.emergeStart = GetGameTimer()
        cam.mode = 'emerge'
        local dur = e.duration
        while cam.mode == 'emerge' and (GetGameTimer() - cam.emergeStart) < dur do Wait(0) end

        -- 4. Stop the loops before blending, so they do not fight the gameplay camera.
        cam.mode = nil
        isNuiOpen = false
        setCustomHudHidden(false)
        FreezeEntityPosition(cache.ped, false)
        RenderScriptCams(false, true, e.blend, true, true)
        Wait(e.blend + 50)
        if previewCam and DoesCamExist(previewCam) then
            DestroyCam(previewCam, false)
            previewCam = nil
        end
        ClearFocus()

        finishSpawn()
    end)
end

-- selectOnFirstSpawn: already spawned this server session, so spawn at the last spot without the selection.
local function spawnWithoutSelection(spawnData)
    if not IsScreenFadedOut() then
        DoScreenFadeOut(150)
        while not IsScreenFadedOut() do Wait(0) end
    end

    local insideProperty = spawnEntersProperty(spawnData)
    local feet
    if not insideProperty then
        -- Inside a property ps-housing teleports; outside, the ped stays hidden until the arrival shows it.
        local x, y, z, w = getCoordsValues(spawnData.coords)
        streamAround(x, y, z, config.blink.stream)
        local gz = resolveGroundZ(x, y, z)
        teleportPed(x, y, gz, w, false)
        waitPedCollision(500)
        feet = vector3(x, y, gz)
    else
        SetEntityVisible(cache.ped, true, false)
    end

    FreezeEntityPosition(cache.ped, false)
    SetEntityInvincible(cache.ped, false)
    triggerSpawnLoad(spawnData)
    Wait(config.emerge.settle)
    DoScreenFadeIn(config.confirm.fade)
    if feet then arrive(feet) end
    finishSpawn(insideProperty)
end

RegisterNUICallback('confirmSpawn', function(_, cb)
    if not selectedSpawn or not selectedSpawn.coords then
        print('[mri_Qspawn] ERRO: Nenhum spawn selecionado ao confirmar')
        cb({ success = false, message = 'no spawn selected' })
        return
    end

    -- Copy before startEmerge clears selectedSpawn.
    local spawnData = {
        coords = selectedSpawn.coords,
        propertyId = selectedSpawn.propertyId,
        apartment = selectedSpawn.first_time and selectedSpawn.key or nil,
        label = selectedSpawn.label
    }

    debug(string.format('[mri_Qspawn] Confirmando spawn: %s', spawnData.label or 'sem label'))
    playUiSound('confirm')
    markTime('spawn confirmado')
    startEmerge(spawnData)

    cb({ success = true })
end)


-- Panel spawns, fetched again on each chooseSpawn so admin edits show up.
local cachedDataSpawns = nil
local function fetchDataSpawns()
    local ok, list = pcall(function()
        return lib.callback.await('mri_Qspawn:server:getSpawns', false)
    end)
    cachedDataSpawns = (ok and type(list) == 'table') and list or {}
    return cachedDataSpawns
end

-- Last location only with a saved position; with no panel spawns either, the city center.
local function addLastLocation(allowFallback)
    local ok, lastLoc, propertyId = pcall(function()
        return lib.callback.await('qbx_spawn:server:getLastLocation', false)
    end)
    if not ok then lastLoc, propertyId = nil, nil end

    local valid = lastLoc and lastLoc.x and lastLoc.y and lastLoc.z
        and not (math.abs(lastLoc.x) < 1.0 and math.abs(lastLoc.y) < 1.0 and math.abs(lastLoc.z) < 1.0)

    if valid then
        spawns[#spawns+1] = {
            label = 'last_location',
            coords = lastLoc,
            icon = 'map-pin',
            propertyId = propertyId
        }
        return
    end

    if not allowFallback or #(cachedDataSpawns or {}) > 0 then return end

    spawns[#spawns+1] = {
        label = locale('city_center'),
        coords = { x = -269.4, y = -955.3, z = 31.2, w = 205.8 },
        icon = 'map-pin',
    }
end

local function addConfigSpawns()
    local data = cachedDataSpawns or {}
    for i = 1, #data do
        local spawn = data[i]
        if spawn and spawn.coords and spawn.label then
            local coords = serializeCoords(spawn.coords)
            if coords then
                spawns[#spawns+1] = {
                    label = spawn.label,
                    coords = coords,
                    icon = spawn.icon or 'map-pin',
                    color = spawn.color,
                }
            end
        end
    end
end

local function addHouses()
    local ok, houses = pcall(function()
        return lib.callback.await('qbx_spawn:server:getHouses', false)
    end)
    if not (ok and houses and #houses > 0) then return end
    for i = 1, #houses do
        local h = houses[i]
        if h and h.coords and h.label then
            spawns[#spawns+1] = {
                label = h.label,
                coords = h.coords,
                propertyId = h.propertyId,
                icon = 'home',
            }
        end
    end
end

local function addApartments(apps)
    if not apps then return end
    for k, v in pairs(apps) do
        if v and v.door and v.door.x and v.door.y and v.door.z then
            spawns[#spawns+1] = {
                first_time = true,
                key = k,
                label = v.label or k,
                coords = vector3(v.door.x, v.door.y, v.door.z),
                icon = 'building',
            }
        end
    end
end

-- opts.new: new character, starter apartments only (opts.apps); opts.fallback: city center when nothing else.
local function loadSpawns(opts)
    opts = opts or {}
    spawns = {}

    if opts.new then
        addApartments(opts.apps)
        return
    end

    fetchDataSpawns()
    addLastLocation(opts.fallback)
    addConfigSpawns()
    addHouses()
end

local function setupSpawnsInternal(citizenid)
    loadSpawns({ fallback = true })
    debug(string.format('[mri_Qspawn] %d spawns configurados', #spawns))
end

-- qbx_core entrypoint (multichar Play).
exports('chooseSpawn', function(citizenid)
    debug(string.format('[mri_Qspawn] chooseSpawn chamado com citizenid: %s', citizenid or 'nil'))
    markTime('chooseSpawn')

    if isNuiOpen then
        print('[mri_Qspawn] AVISO: UI já está aberta, ignorando chooseSpawn')
        return
    end

    SetNuiFocus(false, false) -- the multichar may leave NUI focus on

    -- No fixed wait: the caller already faded out and openSpawnUI fades before touching the scene.
    if previewCam and DoesCamExist(previewCam) then
        stopCamera(0) -- openSpawnUI creates the next one
    end

    selectedSpawn = nil

    setupSpawnsInternal(citizenid)
    markTime('spawns carregados')

    if #spawns == 0 then
        print('[mri_Qspawn] ERRO: Nenhum spawn foi configurado após setupSpawnsInternal!')
        return
    end

    -- spawns[1] is the last location when there is one, else the first panel spot.
    ensureConfig()
    if config.selectOnFirstSpawn and lib.callback.await('qbx_spawn:server:alreadySpawned', false) then
        debug('[mri_Qspawn] Ja spawnou nesta sessao; indo direto pra ultima localizacao.')
        spawnWithoutSelection(spawns[1])
        return
    end

    openSpawnUI()

    -- Block until the selection closes: qbx_core destroys the preview cam once chooseSpawn returns.
    while isNuiOpen do
        Wait(100)
    end
end)

-- Legacy qb-spawn / qbx_spawn flow (ps-housing setupSpawnUI).
AddEventHandler('qb-spawn:client:setupSpawns', function(cData, new, apps)
    debug(string.format('[mri_Qspawn] Evento setupSpawns recebido - new: %s', tostring(new)))
    loadSpawns({ new = new, apps = apps })
    openSpawnUI()
end)

RegisterNUICallback('nuiReady', function(_, cb)
    jsHasMounted = true
    -- The fallback may have sent before the NUI listened, so send again; a second open is harmless.
    sendOpenMessage()
    hasJsSignaledReady = true -- locks only after the resend
    cb('ok')
end)

-- Admin panel. Every answer goes in the cb: inside the mri_Qadmin iframe SendNUIMessage never arrives.

local PLUGIN_ID <const> = 'spawns'
local isAdminPanelOpen = false

local function zoneLabel(c)
    return GetLabelText(GetNameOfZone(c.x + 0.0, c.y + 0.0, c.z + 0.0))
end

-- Panel rows carry the area name; coords go as plain tables (a cb answer drops vector3).
local function adminList(list)
    local out = {}
    for i = 1, #(list or {}) do
        local s = list[i]
        local c = s.coords
        out[i] = {
            id = s.id, label = s.label, icon = s.icon, color = s.color, description = s.description,
            coords = { x = c.x, y = c.y, z = c.z, w = c.w }, zone = zoneLabel(c),
        }
    end
    return out
end

local function fromAdmin(data)
    return type(data) == 'table' and data.embedded == true and GetResourceState('mri_Qadmin') == 'started'
end

local function closeAdminPanel(data)
    if fromAdmin(data) then
        pcall(function() exports.mri_Qadmin:ClosePlugin() end)
        return
    end
    isAdminPanelOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeAdmin' })
end

-- World tool: hide the panel, run the tool on its own thread (a loop inside the NUI callback misses keys), come back.
local function inWorld(data, fn)
    local admin = fromAdmin(data)
    if admin then
        pcall(function() exports.mri_Qadmin:ClosePlugin() end)
    else
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'placing', value = true })
    end
    local done = promise.new()
    CreateThread(function()
        local ok, result = pcall(fn)
        if not ok then lib.print.error(result) end
        done:resolve(ok and result or false)
    end)
    local result = Citizen.Await(done)
    if admin then
        pcall(function() exports.mri_Qadmin:OpenPlugin(PLUGIN_ID) end)
    else
        SendNUIMessage({ action = 'placing', value = false })
        if isAdminPanelOpen then SetNuiFocus(true, true) end
    end
    return result
end

RegisterCommand('adminspawn', function()
    if isAdminPanelOpen then return end
    local isAdmin = lib.callback.await('mri_Qspawn:server:isAdmin', false)
    if not isAdmin then
        lib.notify({ type = 'error', description = locale('no_permission') })
        return
    end

    isAdminPanelOpen = true
    fetchDataSpawns()
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'openAdmin',
        spawns = adminList(cachedDataSpawns),
        accentColor = accentColor,
        backgroundColor = backgroundColor,
        uiConfig = oxLibUiConfig,
        locale = GetConvar('ox:locale', 'en'),
    })
end, false)

RegisterNUICallback('adminClose', function(_, cb)
    closeAdminPanel()
    cb('ok')
end)

-- Embedded mode asks on mount: mri_Qadmin opens the iframe without /adminspawn.
RegisterNUICallback('adminGetSpawns', function(_, cb)
    cb(adminList(fetchDataSpawns()))
end)

-- A see-through copy of the player marks where the character appears and which way it faces.
RegisterNUICallback('adminPlace', function(data, cb)
    if SpawnPlacer.isActive() then return cb(false) end
    local heading = type(data) == 'table' and tonumber(data.heading) or nil
    local result = inWorld(data, function()
        return SpawnPlacer.point({ model = GetEntityModel(cache.ped), heading = heading })
    end)
    if not result then return cb(false) end
    local c = result.coords
    cb({ coords = { x = c.x, y = c.y, z = c.z, w = result.heading }, zone = zoneLabel(c) })
end)

RegisterNUICallback('adminTeleport', function(data, cb)
    local c = type(data) == 'table' and data.coords
    if type(c) ~= 'table' or not tonumber(c.x) or not tonumber(c.y) or not tonumber(c.z) then return cb(false) end
    if not lib.callback.await('mri_Qspawn:server:isAdmin', false) then return cb(false) end
    cb(true)
    closeAdminPanel(data)
    local x, y, z = c.x + 0.0, c.y + 0.0, c.z + 0.0
    RequestCollisionAtCoord(x, y, z)
    -- Flag 32 floods from the point, so the player lands on the nearest walkable spot.
    local found, safe = GetSafeCoordForPed(x, y, z, false, 32)
    if found then x, y, z = safe.x, safe.y, safe.z end
    SetEntityCoords(cache.ped, x, y, z, false, false, false, false)
    if tonumber(c.w) then SetEntityHeading(cache.ped, c.w + 0.0) end
end)

RegisterNUICallback('adminSaveSpawn', function(data, cb)
    local ok, list, id = lib.callback.await('mri_Qspawn:server:saveSpawn', false, {
        id = data.id,
        spawn = data.spawn,
    })
    if ok then cachedDataSpawns = list end
    cb({ success = ok == true, id = id, spawns = adminList(ok and list or cachedDataSpawns) })
end)

RegisterNUICallback('adminDeleteSpawn', function(data, cb)
    local ok, list = lib.callback.await('mri_Qspawn:server:deleteSpawn', false, data.id)
    if ok then cachedDataSpawns = list end
    cb({ success = ok == true, spawns = adminList(ok and list or cachedDataSpawns) })
end)

RegisterNUICallback('adminGetConfig', function(_, cb)
    local cfg = lib.callback.await('mri_Qspawn:server:getConfig', false)
    cb(cfg or {})
end)

RegisterNUICallback('adminSaveConfig', function(payload, cb)
    local ok, result = lib.callback.await('mri_Qspawn:server:saveConfig', false, payload)
    cb({ success = ok == true, config = ok and result or nil })
end)

-- The server broadcasts saved settings; merge in place so the next spawn uses them.
RegisterNetEvent('mri_Qspawn:client:configChanged', function(newConfig)
    if type(newConfig) ~= 'table' then return end
    for k, v in pairs(newConfig) do config[k] = v end
end)

RegisterNetEvent('mri_Qspawn:client:accentColorChanged', function(newColor)
    if type(newColor) ~= 'string' then return end
    -- #RRGGBB or #RRGGBBAA (the NUI theme ignores alpha)
    if not (newColor:match('^#%x%x%x%x%x%x$') or newColor:match('^#%x%x%x%x%x%x%x%x$')) then return end

    accentColor = newColor

    if isNuiOpen or isAdminPanelOpen then
        SendNUIMessage({ action = 'updateAccentColor', accentColor = newColor })
    end
end)

RegisterNetEvent('mri_Qspawn:client:backgroundColorChanged', function(newColor)
    backgroundColor = type(newColor) == 'string' and newColor or ''

    if isNuiOpen or isAdminPanelOpen then
        SendNUIMessage({ action = 'updateBackgroundColor', backgroundColor = backgroundColor })
    end
end)

-- Resource stopped mid-selection: give back focus, camera and the ped, or the player stays stuck.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    if isNuiOpen or isAdminPanelOpen then
        SetNuiFocus(false, false)
    end
    if isNuiOpen then setCustomHudHidden(false) end
    if previewCam and DoesCamExist(previewCam) then
        SetCamActive(previewCam, false)
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(previewCam, true)
        ClearFocus()
    end
    -- Only undo what the selection did: a player frozen by another script stays frozen.
    if isNuiOpen then
        FreezeEntityPosition(cache.ped, false)
        SetEntityInvincible(cache.ped, false)
        SetEntityVisible(cache.ped, true, false)
    end
end)

