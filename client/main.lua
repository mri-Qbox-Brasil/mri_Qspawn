local Waypoints = require 'client.waypoints'
local spawns = {}

-- Runtime cache do config persistido em data/config.json. Hydratado lazy no
-- primeiro uso via lib.callback e mutado in-place pelo broadcast
-- `mri_Qspawn:client:configChanged` (admin salvou pela UI). Nunca leia direto
-- desta tabela antes da hidratacao terminar — use ensureConfig() ou getConfig().
local config = {}
local configHydrated = false

local function ensureConfig()
    if configHydrated then return end
    local data = lib.callback.await('mri_Qspawn:server:getConfig', false)
    if type(data) == 'table' then
        for k, v in pairs(data) do config[k] = v end
    end
    configHydrated = true
    Waypoints.setColorDefault(config.defaultSpawnIconColor)
end

-- accentColor vive separado do `config` porque vem da convar global
-- `mri:color` da suite MRI (nao e tunavel via UI deste plugin). Atualizado
-- pelo handler de `mri_Qspawn:client:accentColorChanged`.
local accentColor = GetConvar('mri:color', '#00E699')

-- Log gated por config.debug; usar print() apenas para erros reais.
local function debug(...)
    if config.debug then print(...) end
end

CreateThread(function()
    -- Hydrata config no boot do client. Nao bloqueia o resto do script;
    -- callers chamam ensureConfig() se precisarem de valor garantido.
    ensureConfig()
end)

local function getTranslatedLabel(label)
    if not label then return label end
    if label == 'last_location' then
        return locale('last_location') or label
    end
    return label
end

local function getTranslatedDescription(label, fallbackDesc)
    if fallbackDesc then return fallbackDesc end
    local displayLabel = (label == 'last_location') and (locale('last_location') or label) or label
    return locale('start_at', displayLabel) or string.format('Comece em %s', displayLabel)
end

local isNuiOpen = false
local previewCam = nil
local scaleform = nil
local selectedSpawn = nil
local selectedSpawnIndex = nil
local hasJsSignaledReady = false -- ack-only: marca que o JS realmente confirmou recepcao
local hasFallbackFired = false   -- distingue "fallback tentou" de "JS confirmou" — sem isso, race entre fallback e mount perdia o `open` (fallback enviava antes do JS escutar e travava o re-send no nuiReady)
local jsHasMounted = false -- React envia nuiReady no mount; usado pra evitar SendNUIMessage antes da UI escutar.

local buildCinematicShots, startCinematic
local currentCinematicTarget

-- Aceita vec3/vec4, {x,y,z,w} e {[1],[2],[3],[4]}.
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

local function setupAerialCamera(cx, cy, cz, kf)
    -- qbx_core multichar deixa a preview cam dele ativa quando dispara chooseSpawn;
    -- sem esse reset a nossa não renderiza.
    RenderScriptCams(false, false, 0, true, true)
    DestroyAllCams(true)

    SetFocusPosAndVel(cx, cy, cz, 0.0, 0.0, 0.0)

    previewCam = CreateCamWithParams(
        'DEFAULT_SCRIPTED_CAMERA',
        cx + kf.dx, cy + kf.dy, cz + kf.dz,
        kf.pitch, kf.roll or 0.0, kf.yaw,
        kf.fov,
        false,
        0
    )

    SetCamActive(previewCam, true)
    RenderScriptCams(true, false, 1, true, true)
end

local function stopCamera()
    if previewCam and DoesCamExist(previewCam) then
        SetCamActive(previewCam, false)
        RenderScriptCams(false, true, 1000, true, true)
        DestroyCam(previewCam, true)
        previewCam = nil
    end

    ClearFocus()

    if scaleform then
        BeginScaleformMovieMethod(scaleform, 'CLEANUP')
        EndScaleformMovieMethod()
        SetScaleformMovieAsNoLongerNeeded(scaleform)
        scaleform = nil
    end
end

local function setupAerialMap()
    CreateThread(function()
        while isNuiOpen and DoesCamExist(previewCam) do
            HideHudComponentThisFrame(6) -- Vehicle Name
            HideHudComponentThisFrame(7) -- Area Name
            HideHudComponentThisFrame(9) -- Vehicle Class
            Wait(0)
        end
    end)
end

local function managePlayer()
    FreezeEntityPosition(cache.ped, true)
    SetEntityInvincible(cache.ped, true)
    SetEntityVisible(cache.ped, false, false)
end

-- Coords dentro de MLO (interior) precisam de LoadInterior pra streamar
-- assets — sem isso o ped cai no vazio e a camera mostra so o ceu/cidade
-- do alto. Retorna true se tem interior carregado nessas coords.
local function loadInteriorIfPresent(x, y, z, timeoutMs)
    local interior = GetInteriorAtCoords(x, y, z)
    if interior == 0 then return false end
    LoadInterior(interior)
    local deadline = GetGameTimer() + (timeoutMs or 3000)
    while not IsInteriorReady(interior) and GetGameTimer() < deadline do
        Wait(10)
    end
    return IsInteriorReady(interior)
end

-- Caller deve ter chamado SetFocusPosAndVel + Wait pra terreno streamar antes;
-- sem isso GetGroundZFor_3dCoord falha e a gente cai no Z do config. Retorna o
-- Z final pra cam math poder mirar na altura real do ped. Quando esta dentro
-- de MLO carrega o interior antes e mantem o Z original (interior tem floor
-- proprio, ground exterior nao se aplica).
local function placePedAtGround(x, y, z, w)
    local insideInterior = loadInteriorIfPresent(x, y, z)

    if not insideInterior then
        local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 5.0, false)
        if found and groundZ > 0.0 then z = groundZ end
    end

    SetEntityCoords(cache.ped, x, y, z, false, false, false, false)
    SetEntityHeading(cache.ped, w or 0.0)
    FreezeEntityPosition(cache.ped, true)
    SetEntityVisible(cache.ped, true, false)
    SetEntityInvincible(cache.ped, true)
    return z
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
                color = Waypoints.colorFor(spawn),
                description = spawn.description or getTranslatedDescription(spawn.label, nil),
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

    isNuiOpen = true
    hasJsSignaledReady = false

    managePlayer()

    local fx, fy, fz, fw = getCoordsValues(spawns[1].coords)
    if not (fx and fy and fz) then
        local pedPos = GetEntityCoords(cache.ped)
        fx, fy, fz, fw = pedPos.x, pedPos.y, pedPos.z, GetEntityHeading(cache.ped)
    end

    DoScreenFadeOut(150)
    while not IsScreenFadedOut() do Wait(0) end

    SetFocusPosAndVel(fx, fy, fz, 0.0, 0.0, 0.0)
    Wait(150) -- Terreno streamar antes do ground detect.

    fz = placePedAtGround(fx, fy, fz, fw)

    local kf = buildCinematicShots(fx, fy, fz, fw)[1].from
    setupAerialCamera(fx, fy, fz, kf)
    setupAerialMap()
    Waypoints.createForSpawns(spawns, getCoordsValues, getTranslatedLabel)

    -- DUIs do waypoint carregam async (load ack via polling); sem esse hold
    -- o fade-in revela elas em estado "vazio" e gera flick no primeiro frame.
    Wait(500)
    DoScreenFadeIn(400)
    while IsScreenFadingIn() do Wait(0) end

    SetNuiFocus(true, true)
    startCinematic(fx, fy, fz, fw)

    if jsHasMounted then
        sendOpenMessage()
    end

    CreateThread(function()
        local timeout = 4000
        local start = GetGameTimer()
        while isNuiOpen and not hasJsSignaledReady do
            if GetGameTimer() - start > timeout then
                print('[mri_Qspawn] AVISO: JS demorou demais ou não carregou. Forçando abertura via fallback...')
                hasFallbackFired = true
                sendOpenMessage()
                break
            end
            Wait(100)
        end
    end)
end

-- Idempotente: chamado pelo nuiReady (JS confirma mount) e pelo fallback de
-- 4s. So bloqueia re-envio depois que o JS ack via nuiReady — fallback NAO
-- bloqueia, pq se ele disparou e o JS ainda nao montou, a msg foi pro vazio
-- e precisa ser re-enviada quando o nuiReady chegar.
function sendOpenMessage()
    if not isNuiOpen or hasJsSignaledReady then return end

    SendNUIMessage({
        action = 'open',
        spawns = serializeSpawns(spawns),
        accentColor = accentColor,
        locale = GetConvar('ox:locale', 'en'),
    })

    if #spawns > 0 then
        selectedSpawn = spawns[1]
        selectedSpawnIndex = 1
    end
end

local isTransitioning = false
local pendingTransitionTarget = nil
local cinematicThread = nil

local function stopCinematic()
    cinematicThread = nil
    currentCinematicTarget = nil
end

local function closeSpawnUI()
    if not isNuiOpen then return end

    isNuiOpen = false
    selectedSpawn = nil
    selectedSpawnIndex = nil
    pendingTransitionTarget = nil
    stopCinematic()
    Waypoints.removeAll()
    SetNuiFocus(false, false)
    stopCamera()

    SendNUIMessage({
        action = 'close',
    })
end

-- Convenção FiveM: yaw 0 = norte (+y), aumenta CCW vista de cima.
local function computeLookRotation(camX, camY, camZ, tgtX, tgtY, tgtZ)
    local dx, dy, dz = tgtX - camX, tgtY - camY, tgtZ - camZ
    local horiz = math.sqrt(dx * dx + dy * dy)
    local pitch = math.deg(math.atan2(dz, horiz))
    local yaw   = math.deg(math.atan2(-dx, dy))
    return pitch, yaw
end

local function applyKeyframe(kf, cx, cy, cz)
    SetCamCoord(previewCam, cx + kf.dx, cy + kf.dy, cz + kf.dz)
    SetCamRot(previewCam, kf.pitch, kf.roll or 0.0, kf.yaw, 0)
    SetCamFov(previewCam, kf.fov)
end

-- Pitch/yaw recomputados nas duas pontas pra manter o spawn centralizado durante
-- toda a aproximação (sem isso a cam derivava do alvo conforme se aproximava).
-- offsetY = distância à frente do ped; rotacionada pelo heading pra cam ficar
-- sempre em frente (ped olha pra cam) independente do `w` do spawn.
function buildCinematicShots(cx, cy, cz, heading)
    local s = config.cinematicShot
    local fwdStart = s.startOffsetY
    local fwdEnd   = s.endOffsetY
    local h = math.rad(heading or 0.0)
    local sinH, cosH = math.sin(h), math.cos(h)

    local startX, startY = cx - sinH * fwdStart, cy + cosH * fwdStart
    local endX,   endY   = cx - sinH * fwdEnd,   cy + cosH * fwdEnd
    local startZ = cz + (s.startOffsetZ or 32.0)
    local endZ   = cz + (s.endOffsetZ   or  9.0)
    local startFov = s.startFov or 65.0
    local endFov   = s.endFov   or 40.0
    local tgtZ = cz + 1.0

    local startPitch, startYaw = computeLookRotation(startX, startY, startZ, cx, cy, tgtZ)
    local endPitch,   endYaw   = computeLookRotation(endX,   endY,   endZ,   cx, cy, tgtZ)

    return {
        {
            duration = config.cinematicDuration, linear = false,
            from = { dx = startX - cx, dy = startY - cy, dz = startZ - cz,
                     pitch = startPitch, roll = 0.0, yaw = startYaw, fov = startFov },
            to   = { dx = endX - cx,   dy = endY - cy,   dz = endZ - cz,
                     pitch = endPitch,  roll = 0.0, yaw = endYaw,   fov = endFov },
        },
    }
end

-- `shot.linear = true` desativa o easing; padrão usa ease in/out cúbico.
local function runShot(shot, cx, cy, cz, alive)
    local segStart = GetGameTimer()
    local f, to = shot.from, shot.to
    local linear = shot.linear == true
    while alive() do
        local progress = math.min((GetGameTimer() - segStart) / shot.duration, 1.0)
        local t = linear and progress
            or (progress < 0.5 and 4 * progress * progress * progress
                or 1 - math.pow(-2 * progress + 2, 3) / 2)

        SetCamCoord(previewCam,
            cx + f.dx + (to.dx - f.dx) * t,
            cy + f.dy + (to.dy - f.dy) * t,
            cz + f.dz + (to.dz - f.dz) * t)
        SetCamRot(previewCam,
            f.pitch + (to.pitch - f.pitch) * t,
            (f.roll or 0.0) + ((to.roll or 0.0) - (f.roll or 0.0)) * t,
            f.yaw + (to.yaw - f.yaw) * t,
            0)
        SetCamFov(previewCam, f.fov + (to.fov - f.fov) * t)

        if progress >= 1.0 then break end
        Wait(0)
    end
end

function startCinematic(cx, cy, cz, heading)
    stopCinematic()
    local thisThread = {}
    cinematicThread = thisThread
    currentCinematicTarget = { x = cx, y = cy, z = cz }

    CreateThread(function()
        local shot = buildCinematicShots(cx, cy, cz, heading)[1]
        local function alive()
            return cinematicThread == thisThread and DoesCamExist(previewCam)
        end
        if alive() then runShot(shot, cx, cy, cz, alive) end
    end)
end

-- Cliques durante uma transição armazenam o último target em pendingTransitionTarget
-- e são processados assim que a transição atual termina.
local function moveCameraToLocation(coords)
    if not previewCam or not DoesCamExist(previewCam) then return end

    local x, y, z, w = getCoordsValues(coords)
    if not (x and y and z) then return end

    -- Auto-select reentrante após openSpawnUI ou clique no spawn já selecionado.
    if currentCinematicTarget then
        local ddx = currentCinematicTarget.x - x
        local ddy = currentCinematicTarget.y - y
        local ddz = currentCinematicTarget.z - z
        if ddx * ddx + ddy * ddy + ddz * ddz < 1.0 then return end
    end

    if isTransitioning then
        pendingTransitionTarget = { x = x, y = y, z = z, w = w }
        return
    end

    isTransitioning = true
    CreateThread(function()
        local fadeDuration = config.transitionFadeDuration
        local tx, ty, tz, tw = x, y, z, w

        while tx do
            stopCinematic()
            DoScreenFadeOut(fadeDuration)
            while not IsScreenFadedOut() do Wait(0) end

            SetFocusPosAndVel(tx, ty, tz, 0.0, 0.0, 0.0)
            Wait(100) -- Terreno streamar antes do ground detect.

            tz = placePedAtGround(tx, ty, tz, tw)

            applyKeyframe(buildCinematicShots(tx, ty, tz, tw)[1].from, tx, ty, tz)

            DoScreenFadeIn(fadeDuration)
            while IsScreenFadingIn() do Wait(0) end

            startCinematic(tx, ty, tz, tw)

            local pending = pendingTransitionTarget
            pendingTransitionTarget = nil
            if pending then
                tx, ty, tz, tw = pending.x, pending.y, pending.z, pending.w
            else
                tx = nil
            end
        end
        isTransitioning = false
    end)
end

local function zoomCameraToPlayer(coords, spawnData, duration, callback)
    duration = duration or config.zoomDuration

    if not previewCam or not DoesCamExist(previewCam) then
        print('[mri_Qspawn] ERRO: Câmera não existe para zoomCameraToPlayer')
        if callback then callback() end
        return
    end

    local x, y, z, w = getCoordsValues(coords)
    if not (x and y and z) then
        print('[mri_Qspawn] ERRO: Coordenadas inválidas para zoomCameraToPlayer')
        if callback then callback() end
        return
    end

    -- Remove DUI markers: em close range clipam com o ped/cam.
    Waypoints.removeAll()
    SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)

    CreateThread(function()
        stopCinematic()

        local pedZ = placePedAtGround(x, y, z, w)

        -- Em frente ao ped a 2m + 4m de altura — continua a aproximação heading-relative.
        local rad = math.rad(w or 0.0)
        local endX, endY = x - math.sin(rad) * 2.0, y + math.cos(rad) * 2.0
        local endZ = pedZ + 4.0
        local pitch, yaw = computeLookRotation(endX, endY, endZ, x, y, pedZ + 1.0)

        -- graphType 0 = cubic ease (snappy no início, soft no final).
        SetCamParams(previewCam,
            endX, endY, endZ,
            pitch, 0.0, yaw,
            32.0,
            duration, 0, 0, 0)
        Wait(duration)

        if callback then callback(spawnData) end
    end)
end

RegisterNUICallback('getSpawns', function(_, cb)
    cb({ success = true, spawns = serializeSpawns(spawns) })
end)

RegisterNUICallback('selectSpawn', function(data, cb)
    local spawnIndex = data.index + 1 -- React usa índice 0, Lua usa 1.
    if not spawnIndex or spawnIndex < 1 or spawnIndex > #spawns then
        cb({ success = false, message = 'Spawn inválido' })
        return
    end

    local spawnData = spawns[spawnIndex]
    if not spawnData or not spawnData.coords then
        cb({ success = false, message = 'Spawn sem coordenadas' })
        return
    end

    selectedSpawn = spawnData
    selectedSpawnIndex = spawnIndex

    debug(string.format('[mri_Qspawn] Spawn selecionado: %s (índice %d)', spawnData.label or 'sem label', spawnIndex))

    moveCameraToLocation(spawnData.coords)
    cb({ success = true })
end)

local function playSimpleSpawnAnimation()
    CreateThread(function()
        Wait(300)

        local playerPed = PlayerPedId()
        if not playerPed or playerPed == 0 then
            return
        end

        local animations = config.spawnAnimations

        if #animations == 0 then return end

        local selectedAnimation = animations[math.random(#animations)]
        local duration = config.spawnAnimationDuration

        TaskStartScenarioInPlace(playerPed, selectedAnimation, 0, true)
        Wait(duration)
        ClearPedTasks(playerPed)
    end)
end

RegisterNUICallback('confirmSpawn', function(_, cb)
    if not selectedSpawn or not selectedSpawn.coords then
        print('[mri_Qspawn] ERRO: Nenhum spawn selecionado ao confirmar')
        cb({ success = false, message = 'Nenhum spawn selecionado' })
        return
    end

    -- Snapshot antes do callback async limpar selectedSpawn.
    local spawnData = {
        coords = selectedSpawn.coords,
        propertyId = selectedSpawn.propertyId,
        label = selectedSpawn.label
    }

    debug(string.format('[mri_Qspawn] Confirmando spawn: %s', spawnData.label or 'sem label'))

    zoomCameraToPlayer(spawnData.coords, spawnData, config.zoomDuration, function(spawnInfo)
        DoScreenFadeOut(500)
        while not IsScreenFadedOut() do Wait(0) end

        closeSpawnUI()
        selectedSpawn = nil
        selectedSpawnIndex = nil

        FreezeEntityPosition(cache.ped, false)
        SetEntityVisible(cache.ped, true, false)
        SetEntityInvincible(cache.ped, false)

        if spawnInfo and spawnInfo.propertyId then
            TriggerServerEvent('ps-housing:server:enterProperty', tostring(spawnInfo.propertyId), 'spawn')
        elseif spawnInfo and spawnInfo.label == 'last_location' then
            if QBX and QBX.PlayerData and QBX.PlayerData.metadata then
                local insideMeta = QBX.PlayerData.metadata["inside"]
                if insideMeta and insideMeta.property_id then
                    TriggerServerEvent('ps-housing:server:enterProperty', tostring(insideMeta.property_id))
                end
            end
        end

        TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
        TriggerEvent('QBCore:Client:OnPlayerLoaded')

        -- illenium-appearance reaplica o ped no OnPlayerLoaded; hold extra esconde o flick.
        Wait(1000)

        DoScreenFadeIn(500)
        Wait(500)

        playSimpleSpawnAnimation()

        if GetResourceState('mri_Qmultichar'):find('start') then
            TriggerServerEvent('mri_Qmultichar:server:setBucket', 0)
        end

        TriggerServerEvent('qbx_spawn:server:spawn')
        debug('[mri_Qspawn] Spawn completado')
    end)

    cb({ success = true })
end)


-- Cache dos spawns que vêm do data/spawns.json via callback. Refrescado a cada
-- chooseSpawn pra refletir alterações feitas pelo painel admin.
local cachedDataSpawns = nil
local function fetchDataSpawns()
    local ok, list = pcall(function()
        return lib.callback.await('mri_Qspawn:server:getSpawns', false)
    end)
    cachedDataSpawns = (ok and type(list) == 'table') and list or {}
    return cachedDataSpawns
end

-- Retorna true se consumiu dataSpawns[1] como fallback — caller usa pra pular
-- esse índice em addConfigSpawns e evitar duplicação.
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
            description = getTranslatedDescription('last_location', 'Start at last location'),
            propertyId = propertyId
        }
        return false
    end

    if not allowFallback then return false end

    local data = cachedDataSpawns or {}
    local fallbackCoords = data[1] and serializeCoords(data[1].coords)
    spawns[#spawns+1] = {
        label = 'last_location',
        coords = fallbackCoords or { x = -269.4, y = -955.3, z = 31.2, w = 205.8 },
        icon = 'map-pin',
        description = 'Start at last location',
        propertyId = nil
    }
    return fallbackCoords ~= nil
end

local function addConfigSpawns(skipFirst)
    local data = cachedDataSpawns or {}
    if #data == 0 then return end
    for i = (skipFirst and 2 or 1), #data do
        local spawn = data[i]
        if spawn and spawn.coords and spawn.label then
            local coords = serializeCoords(spawn.coords)
            if coords then
                spawns[#spawns+1] = {
                    label = spawn.label,
                    coords = coords,
                    icon = spawn.icon or 'map-pin',
                    color = spawn.color,
                    description = spawn.description or getTranslatedDescription(spawn.label, string.format('Start at %s', spawn.label))
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
                description = string.format('Start at %s', h.label)
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
                description = string.format('Start at %s', v.label or k)
            }
        end
    end
end

-- opts.new = true       → personagem novo, mostra apenas apartamentos (opts.apps).
-- opts.fallback = true  → garante last_location mesmo sem dados do servidor.
local function loadSpawns(opts)
    opts = opts or {}
    spawns = {}

    if opts.new then
        addApartments(opts.apps)
        return
    end

    fetchDataSpawns()
    local consumedFirst = addLastLocation(opts.fallback)
    addConfigSpawns(consumedFirst)
    addHouses()
end

local function setupSpawnsInternal(citizenid)
    loadSpawns({ fallback = true })
    debug(string.format('[mri_Qspawn] %d spawns configurados', #spawns))
end

-- Entrypoint do qbx_core (multichar → "Play").
exports('chooseSpawn', function(citizenid)
    debug(string.format('[mri_Qspawn] chooseSpawn chamado com citizenid: %s', citizenid or 'nil'))

    if isNuiOpen then
        print('[mri_Qspawn] AVISO: UI já está aberta, ignorando chooseSpawn')
        return
    end

    SetNuiFocus(false, false) -- multichar pode deixar a NUI focada.
    Wait(300)

    if previewCam and DoesCamExist(previewCam) then
        stopCamera()
        Wait(200)
    end

    selectedSpawn = nil
    selectedSpawnIndex = nil

    setupSpawnsInternal(citizenid)

    if #spawns == 0 then
        print('[mri_Qspawn] ERRO: Nenhum spawn foi configurado após setupSpawnsInternal!')
        return
    end

    openSpawnUI()

    -- Bloqueia até o usuário fechar a UI; sem isso qbx_core chama destroyPreviewCam
    -- logo após chooseSpawn retornar, matando o render da nossa script cam.
    while isNuiOpen do
        Wait(100)
    end
end)

-- Compat com o fluxo legacy do qb-spawn / qbx_spawn (evento + apps).
AddEventHandler('qb-spawn:client:setupSpawns', function(cData, new, apps)
    debug(string.format('[mri_Qspawn] Evento setupSpawns recebido - new: %s', tostring(new)))
    loadSpawns({ new = new, apps = apps })
    openSpawnUI()
end)

RegisterNUICallback('nuiReady', function(_, cb)
    jsHasMounted = true
    -- Se o fallback ja enviou antes do JS escutar, re-envia agora pra garantir
    -- que o React receba. Idempotente do lado JS — receber `open` 2x ok.
    if hasFallbackFired then hasFallbackFired = false end
    sendOpenMessage()
    hasJsSignaledReady = true -- so trava DEPOIS de garantir o re-envio
    cb('ok')
end)

-- ============================================================
-- Painel admin (CRUD de spawns)
-- ============================================================

local isAdminPanelOpen = false

RegisterCommand('adminspawn', function()
    if isAdminPanelOpen then return end
    local isAdmin = lib.callback.await('mri_Qspawn:server:isAdmin', false)
    if not isAdmin then
        lib.notify({ type = 'error', description = 'Sem permissão pra abrir o painel.' })
        return
    end

    isAdminPanelOpen = true
    fetchDataSpawns()
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'openAdmin',
        spawns = cachedDataSpawns or {},
        accentColor = accentColor,
        locale = GetConvar('ox:locale', 'en'),
    })
end, false)

RegisterNUICallback('adminClose', function(_, cb)
    isAdminPanelOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'closeAdmin' })
    cb('ok')
end)

-- Fetch on-demand pra modo embedded (Qadmin abre iframe sem passar pelo
-- comando /adminspawn que push spawns via SendNUIMessage). Server gateia
-- saveSpawn/deleteSpawn por isAdmin entao quem nao tem perm consegue ver
-- a lista mas nao consegue mutar.
RegisterNUICallback('adminGetSpawns', function(_, cb)
    fetchDataSpawns()
    cb(cachedDataSpawns or {})
end)

-- Captura a coord/heading atual do ped pra preencher o form (botão "usar minha posição").
RegisterNUICallback('adminGetMyCoords', function(_, cb)
    local pos = GetEntityCoords(cache.ped)
    cb({
        x = pos.x, y = pos.y, z = pos.z,
        w = GetEntityHeading(cache.ped),
    })
end)

RegisterNUICallback('adminSaveSpawn', function(data, cb)
    local ok, list = lib.callback.await('mri_Qspawn:server:saveSpawn', false, {
        index = data.index,
        spawn = data.spawn,
    })
    if ok then cachedDataSpawns = list end
    cb({ success = ok == true, spawns = list or cachedDataSpawns or {} })
end)

RegisterNUICallback('adminDeleteSpawn', function(data, cb)
    local ok, list = lib.callback.await('mri_Qspawn:server:deleteSpawn', false, data.index)
    if ok then cachedDataSpawns = list end
    cb({ success = ok == true, spawns = list or cachedDataSpawns or {} })
end)

-- Aba "Configurações" do /adminspawn — fetch + save dos 5 settings tunaveis.
RegisterNUICallback('adminGetConfig', function(_, cb)
    local cfg = lib.callback.await('mri_Qspawn:server:getConfig', false)
    cb(cfg or {})
end)

RegisterNUICallback('adminSaveConfig', function(payload, cb)
    local ok, result = lib.callback.await('mri_Qspawn:server:saveConfig', false, payload)
    cb({ success = ok == true, config = ok and result or nil })
end)

-- Runtime: server broadcasta quando config muda. Mescla na tabela `config`
-- (do require) pra novas chamadas de spawn pegarem os valores atualizados
-- sem precisar de restart.
RegisterNetEvent('mri_Qspawn:client:configChanged', function(newConfig)
    if type(newConfig) ~= 'table' then return end
    for k, v in pairs(newConfig) do config[k] = v end
    Waypoints.setColorDefault(config.defaultSpawnIconColor)
end)

RegisterNetEvent('mri_Qspawn:client:accentColorChanged', function(newColor)
    if type(newColor) ~= 'string' then return end
    if not newColor:match('^#%x%x%x%x%x%x$') then return end

    accentColor = newColor

    if isNuiOpen or isAdminPanelOpen then
        SendNUIMessage({ action = 'updateAccentColor', accentColor = newColor })
    end
end)

