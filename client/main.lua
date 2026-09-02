local Waypoints = require 'client.waypoints'
local spawns = {}

-- Runtime cache do config persistido em data/config.json. Hydratado lazy no
-- primeiro uso via lib.callback e mutado in-place pelo broadcast
-- `mri_Qspawn:client:configChanged` (admin salvou pela UI). Nunca leia direto
-- desta tabela antes da hidratacao terminar — use ensureConfig() ou getConfig().
local config = {}
local configHydrated = false
local configLoading = false

local function ensureConfig()
    if configHydrated then return end
    -- Guard de reentrada: segunda corrotina aguarda enquanto a primeira carrega.
    -- Sem isso, duas corrotinas passam pelo check antes do await e disparam dois
    -- callbacks ao servidor desnecessariamente.
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
    Waypoints.setColorDefault(config.defaultSpawnIconColor)
end

-- accentColor vive separado do `config` porque vem da convar global
-- `mri:color` da suite MRI (nao e tunavel via UI deste plugin). Atualizado
-- pelo handler de `mri_Qspawn:client:accentColorChanged`.
local accentColor = GetConvar('mri:color', '#00E699')
local backgroundColor = GetConvar('mri:backgroundColor', '')

-- Estilo visual do painel /uiconfig do ox_lib (radius, fonte, tema glass, cores
-- de status, dims), lido direto do ox_lib pra a UI standalone herdar a cara do
-- servidor (nao so quando embedado no Qadmin). Cacheado; atualizado pelo evento
-- ox_lib:uiConfigChanged. nil se o ox_lib nao estiver rodando.
local oxLibUiConfig = nil
local function fetchOxLibUiConfig()
    if GetResourceState('ox_lib') ~= 'started' then return end
    local ok, cfg = pcall(function() return lib.callback.await('ox_lib:getUiConfig', false) end)
    if ok then oxLibUiConfig = cfg end
end
fetchOxLibUiConfig()

-- /uiconfig mudou (admin salvou no painel do ox_lib) — recacheia e reaplica na
-- NUI standalone sem precisar reabrir.
RegisterNetEvent('ox_lib:uiConfigChanged', function(cfg)
    oxLibUiConfig = cfg
    SendNUIMessage({ action = 'updateUiConfig', uiConfig = cfg })
end)

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
local hasJsSignaledReady = false -- ack-only: marca que o JS realmente confirmou recepcao
local hasFallbackFired = false   -- distingue "fallback tentou" de "JS confirmou" — sem isso, race entre fallback e mount perdia o `open` (fallback enviava antes do JS escutar e travava o re-send no nuiReady)
local jsHasMounted = false -- React envia nuiReady no mount; usado pra evitar SendNUIMessage antes da UI escutar.

-- Controlador de câmera — PRESENÇA em 1ª pessoa. O jogador "está" no local,
-- em primeira pessoa (câmera na altura dos olhos, olhando pro heading do spawn),
-- com um balanço idle sutil (respiração). Trocar de local = "piscar" (match-cut:
-- fade-out rápido → reposiciona → fade-in). Forward-declarado aqui porque
-- openSpawnUI/selectSpawn/confirmSpawn (acima) precisam chamar.
local createCam, startCameraLoop, requestShowLocation, startEmerge
local resolveGroundZ, teleportPed, setupShot
local cam = {
    mode = nil,        -- 'presence'
    target = nil,      -- { x, y, z=groundZ, w } spawn corrente
    eyeZ = 0.0,        -- altura dos olhos (groundZ + presence.eyeHeight)
    busy = false,      -- true durante o "piscar" (troca de local)
    pendingCoords = nil,
}

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

-- Cria a script cam já ativa. O render loop assume o controle no frame seguinte,
-- então os params iniciais são irrelevantes (só precisam existir). Depth-of-field
-- shallow é aplicado aqui e "acordado" por frame no loop via SetUseHiDof().
createCam = function(cx, cy, cz)
    -- qbx_core multichar deixa a preview cam dele ativa quando dispara chooseSpawn;
    -- sem esse reset a nossa não renderiza.
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
            HideHudAndRadarThisFrame() -- some todo o HUD/minimapa do jogo
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
-- Resolve o Z do chão sem mover o ped (usado pra mirar a câmera na altura real).
-- Dentro de MLO mantém o Z original (interior tem floor próprio). Caller deve ter
-- feito SetFocusPosAndVel + Wait pro terreno streamar antes.
resolveGroundZ = function(x, y, z)
    if loadInteriorIfPresent(x, y, z) then return z end
    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 5.0, false)
    if found and groundZ > 0.0 then return groundZ end
    return z
end

-- Teleporta o ped (congelado/invencível) pra coord. `visible` controla se ele
-- aparece — durante o voo entre spawns fica invisível pra não "piscar" no ar.
teleportPed = function(x, y, z, w, visible)
    SetEntityCoords(cache.ped, x, y, z, false, false, false, false)
    SetEntityHeading(cache.ped, w or 0.0)
    FreezeEntityPosition(cache.ped, true)
    SetEntityVisible(cache.ped, visible ~= false, false)
    SetEntityInvincible(cache.ped, true)
end

-- Força a cena a carregar nas coords e ESPERA (com timeout) antes de revelar —
-- evita ver o mapa "montando" ao trocar de local. Combina focus + collision +
-- NewLoadScene (que streama LOD/props/texturas de verdade).
local function streamAround(x, y, z, maxMs)
    SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)
    RequestCollisionAtCoord(x, y, z)
    NewLoadSceneStartSphere(x, y, z, 80.0, 0)
    local deadline = GetGameTimer() + (maxMs or 1500)
    while not IsNewLoadSceneLoaded() and GetGameTimer() < deadline do
        RequestCollisionAtCoord(x, y, z)
        Wait(0)
    end
    NewLoadSceneStop()
end

-- Espera a colisão carregar sob o ped (chão sólido) antes de revelar, pra ele
-- não cair no vazio no frame do fade-in.
local function waitPedCollision(maxMs)
    local deadline = GetGameTimer() + (maxMs or 500)
    while not HasCollisionLoadedAroundEntity(cache.ped) and GetGameTimer() < deadline do
        local pc = GetEntityCoords(cache.ped)
        RequestCollisionAtCoord(pc.x, pc.y, pc.z)
        Wait(0)
    end
end

-- Sons de UI (frontend nativo do GTA — sem asset). Gated por config.sound.enabled.
local UI_SOUNDS = {
    blink   = { name = 'NAV_UP_DOWN', set = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    confirm = { name = 'SELECT',      set = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
}
local function playUiSound(kind)
    if not (config.sound and config.sound.enabled ~= false) then return end
    local s = UI_SOUNDS[kind]
    if s then PlaySoundFrontend(-1, s.name, s.set, true) end
end

-- Esconde/mostra a HUD do servidor durante a seleção via o statebag `hideHud`
-- do player (contrato de estado que o mri_Qhud e afins escutam). Desacoplado:
-- não hardcoda resource; qualquer HUD que ouça esse bag reage. Replicado.
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

    ensureConfig() -- garante config hidratado (labels/postfx/câmera dependem dele)

    isNuiOpen = true
    hasJsSignaledReady = false

    managePlayer()
    setCustomHudHidden(true) -- esconde a HUD do servidor enquanto seleciona o spawn

    local fx, fy, fz, fw = getCoordsValues(spawns[1].coords)
    if not (fx and fy and fz) then
        local pedPos = GetEntityCoords(cache.ped)
        fx, fy, fz, fw = pedPos.x, pedPos.y, pedPos.z, GetEntityHeading(cache.ped)
    end

    DoScreenFadeOut(150)
    while not IsScreenFadedOut() do Wait(0) end

    -- Carrega o mundo no primeiro local antes de revelar.
    streamAround(fx, fy, fz, (config.blink and config.blink.stream) or 1500)

    -- Ped fica ESCONDIDO durante a seleção (1ª pessoa: a câmera está nos olhos
    -- dele). Posicionado no local pra o confirmar spawnar no lugar certo.
    fz = resolveGroundZ(fx, fy, fz)
    teleportPed(fx, fy, fz, fw, false)
    waitPedCollision(500)

    -- Estado inicial: presença no primeiro local.
    cam.pendingCoords = nil
    cam.busy = false
    setupShot(fx, fy, fz, fw)
    cam.mode = 'presence'

    createCam(fx, fy, fz)
    setupAerialMap()
    if config.showWorldLabels then
        Waypoints.createForSpawns(spawns, getCoordsValues, getTranslatedLabel)
    end
    startCameraLoop()

    -- Segura antes do fade-in pra câmera renderizar o primeiro frame da chegada
    -- (e, com labels ligados, esperar as DUIs carregarem e evitar flick).
    Wait(config.showWorldLabels and 500 or 200)
    DoScreenFadeIn(400)
    while IsScreenFadingIn() do Wait(0) end

    SetNuiFocus(true, true)

    if jsHasMounted then
        sendOpenMessage()
    else
        -- React ainda não montou (race só no primeiro load do resource): re-envia
        -- quando montar (via nuiReady) ou força após timeout. Em aberturas normais
        -- jsHasMounted já é true e nem entra aqui.
        CreateThread(function()
            local start = GetGameTimer()
            while isNuiOpen and not jsHasMounted do
                if GetGameTimer() - start > 8000 then
                    debug('[mri_Qspawn] React demorou pra montar; forçando abertura via fallback.')
                    hasFallbackFired = true
                    sendOpenMessage()
                    break
                end
                Wait(100)
            end
        end)
    end
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
        backgroundColor = backgroundColor,
        uiConfig = oxLibUiConfig,
        locale = GetConvar('ox:locale', 'en'),
        ui = {
            letterbox = config.letterbox,
            vignette = not (config.postfx and config.postfx.vignette == false),
            grain = not (config.postfx and config.postfx.grain == false),
        },
    })

    if #spawns > 0 then
        selectedSpawn = spawns[1]
    end
end

local function closeSpawnUI()
    if not isNuiOpen then return end

    isNuiOpen = false
    selectedSpawn = nil
    cam.mode = nil
    cam.busy = false
    cam.pendingCoords = nil
    Waypoints.removeAll()
    SetNuiFocus(false, false)
    stopCamera()
    setCustomHudHidden(false) -- restaura a HUD do servidor

    SendNUIMessage({
        action = 'close',
    })
end

-- ============================================================
-- Motor de câmera — PRESENÇA em 1ª pessoa (+ "piscar" / match-cut)
--
-- O jogador ESTÁ no local, em primeira pessoa (câmera nos olhos, olhando pro
-- heading do spawn), com um balanço idle sutil (respiração). Trocar de local =
-- "piscar": fade-out rápido → reposiciona/streama → fade-in. Sem menu, sem
-- deslocamento de câmera → zero enjoo. O ped fica escondido (a câmera está nos
-- olhos dele) mas posicionado, pra o confirmar spawnar no lugar certo.
-- ============================================================

-- Define a presença no local: alvo + altura dos olhos. `gz` = Z do chão resolvido.
setupShot = function(tx, ty, gz, w)
    cam.target = { x = tx, y = ty, z = gz, w = w }
    cam.eyeZ = gz + config.presence.eyeHeight
end

-- 1ª pessoa: câmera nos olhos, olhando pro heading, com respiração sutil (sway).
local function updatePresence()
    local p = config.presence
    local t = cam.target
    if not t then return end
    local sway = p.sway
    local now = GetGameTimer() / 1000.0

    local swX  = math.sin(now * 0.7)  * 0.010 * sway
    local swY  = math.cos(now * 0.9)  * 0.010 * sway
    local bobZ = math.sin(now * 1.1)  * 0.012 * sway
    local yawS = math.sin(now * 0.5)  * 0.35  * sway -- graus
    local pitS = math.sin(now * 0.65) * 0.25  * sway -- graus

    SetCamCoord(previewCam, t.x + swX, t.y + swY, cam.eyeZ + bobZ)
    SetCamRot(previewCam, p.pitch + pitS, 0.0, (t.w or 0.0) + yawS, 0)
    SetCamFov(previewCam, p.fov)
end

-- Trocar de local = "piscar" (match-cut): fade-out rápido → reposiciona o ped
-- (escondido) e streama → nova presença → fade-in. Enfileira o último pedido se
-- já estiver piscando.
requestShowLocation = function(coords)
    if cam.mode ~= 'presence' then return end
    local x, y, z, w = getCoordsValues(coords)
    if not (x and y and z) then return end
    if cam.target then
        local dx, dy, dz = cam.target.x - x, cam.target.y - y, cam.target.z - z
        if dx * dx + dy * dy + dz * dz < 1.0 then return end -- dedup
    end
    if cam.busy then cam.pendingCoords = coords; return end

    cam.busy = true
    playUiSound('blink')
    CreateThread(function()
        local b = config.blink
        DoScreenFadeOut(b.out)
        while not IsScreenFadedOut() do Wait(0) end

        -- Carrega o mundo no destino ANTES de revelar (fica preto durante o load,
        -- não mostrando o mapa montar). Sai assim que carrega (perto = rápido).
        streamAround(x, y, z, b.stream)
        if not isNuiOpen or not previewCam or not DoesCamExist(previewCam) then
            cam.busy = false; return
        end

        local gz = resolveGroundZ(x, y, z)
        teleportPed(x, y, gz, w, false) -- ped escondido no novo local
        waitPedCollision(500)
        setupShot(x, y, gz, w)
        updatePresence() -- posiciona a câmera já no primeiro frame

        DoScreenFadeIn(b['in'])
        cam.busy = false

        local pending = cam.pendingCoords
        cam.pendingCoords = nil
        if pending then requestShowLocation(pending) end
    end)
end

local function easeInOut(p)
    if p < 0.5 then return 4 * p * p * p end
    return 1 - math.pow(-2 * p + 2, 3) / 2
end

-- "Nascimento" (confirmar): a câmera SAI da 1ª pessoa (olhos) puxando pra trás e
-- um pouco pra cima até a 3ª pessoa atrás do ped, revelando o personagem no
-- mundo. O ped só aparece um pouco depois do início (quando a lente já saiu da
-- cabeça). No fim, blend pro gameplay cam. Sem fade.
local function updateEmerge()
    local e = config.emerge
    local p = config.presence
    local t = cam.target
    if not t then return end
    local prog = math.min((GetGameTimer() - cam.emergeStart) / e.duration, 1.0)
    local tt = easeInOut(prog)

    -- Revela o ped só quando a lente JÁ SAIU da cabeça (distância real percorrida
    -- pra trás > ~0.45m), senão pisca o interior da cabeça no primeiro frame.
    if not cam.emergeRevealed and tt * e.distance > 0.45 then
        SetEntityVisible(cache.ped, true, false)
        cam.emergeRevealed = true
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
        cb({ success = false, message = 'Índice inválido' })
        return
    end
    local spawnIndex = data.index + 1 -- React usa índice 0, Lua usa 1.
    if spawnIndex < 1 or spawnIndex > #spawns then
        cb({ success = false, message = 'Spawn inválido' })
        return
    end

    local spawnData = spawns[spawnIndex]
    if not spawnData or not spawnData.coords then
        cb({ success = false, message = 'Spawn sem coordenadas' })
        return
    end

    selectedSpawn = spawnData

    debug(string.format('[mri_Qspawn] Spawn selecionado: %s (índice %d)', spawnData.label or 'sem label', spawnIndex))

    requestShowLocation(spawnData.coords)
    cb({ success = true })
end)

local function playSimpleSpawnAnimation()
    CreateThread(function()
        Wait(300)

        local animations = config.spawnAnimations
        if not animations or #animations == 0 then return end

        local selectedAnimation = animations[math.random(#animations)]
        local duration = config.spawnAnimationDuration or 3000

        TaskStartScenarioInPlace(cache.ped, selectedAnimation, 0, true)
        Wait(duration)
        ClearPedTasks(cache.ped)
    end)
end

-- Dispara os eventos de carga do player (housing + OnPlayerLoaded). Ideal com o
-- ped ESCONDIDO: o reapply de aparência (illenium) fica oculto.
local function triggerSpawnLoad(spawnInfo)
    if spawnInfo.propertyId then
        TriggerServerEvent('ps-housing:server:enterProperty', tostring(spawnInfo.propertyId), 'spawn')
    elseif spawnInfo.label == 'last_location' and QBX and QBX.PlayerData and QBX.PlayerData.metadata then
        local insideMeta = QBX.PlayerData.metadata['inside']
        if insideMeta and insideMeta.property_id then
            TriggerServerEvent('ps-housing:server:enterProperty', tostring(insideMeta.property_id))
        end
    end
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
    TriggerEvent('QBCore:Client:OnPlayerLoaded')
end

-- True se o spawn cai dentro de uma propriedade (housing assume câmera/teleporte,
-- então usamos fade em vez do "nascimento" cinematográfico).
local function spawnEntersProperty(spawnInfo)
    if spawnInfo.propertyId then return true end
    if spawnInfo.label == 'last_location' and QBX and QBX.PlayerData and QBX.PlayerData.metadata then
        local insideMeta = QBX.PlayerData.metadata['inside']
        return insideMeta ~= nil and insideMeta.property_id ~= nil
    end
    return false
end

local function finishSpawn()
    playSimpleSpawnAnimation()
    if GetResourceState('mri_Qmultichar'):find('start') then
        TriggerServerEvent('mri_Qmultichar:server:setBucket', 0)
    end
    TriggerServerEvent('qbx_spawn:server:spawn')
    debug('[mri_Qspawn] Spawn completado')
end

startEmerge = function(spawnData)
    CreateThread(function()
        -- Espera terminar um "piscar" em andamento pra sair de um estado estável.
        local deadline = GetGameTimer() + 6000
        while isNuiOpen and cam.busy and GetGameTimer() < deadline do Wait(50) end
        if not isNuiOpen or not previewCam or not DoesCamExist(previewCam) then return end

        local e = config.emerge

        -- Fecha a NUI (a câmera continua nossa até o blend). isNuiOpen segue true
        -- pra o render loop e o hide-hud continuarem rodando durante o nascimento.
        selectedSpawn = nil
        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'close' })

        if spawnEntersProperty(spawnData) then
            -- Cai dentro de casa: fade (o housing assume câmera/teleporte).
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
            finishSpawn()
            return
        end

        -- 1. Carga com o ped ESCONDIDO (aparência reaplica oculta).
        triggerSpawnLoad(spawnData)
        Wait(e.settle)
        if not previewCam or not DoesCamExist(previewCam) then isNuiOpen = false; return end

        -- 2. Reafirma o ped no local (OnPlayerLoaded pode ter mexido), ainda oculto.
        teleportPed(cam.target.x, cam.target.y, cam.target.z, cam.target.w, false)
        SetEntityInvincible(cache.ped, false)

        -- 3. Câmera SAI da 1ª pessoa até a 3ª pessoa (sem fade). updateEmerge revela
        --    o ped no meio do movimento.
        cam.emergeRevealed = false
        cam.emergeStart = GetGameTimer()
        cam.mode = 'emerge'
        local dur = e.duration
        while cam.mode == 'emerge' and (GetGameTimer() - cam.emergeStart) < dur do Wait(0) end

        -- 4. Blend pro gameplay cam e entrega o controle. Para os loops ANTES do
        --    blend pra o render loop não brigar com a câmera de gameplay.
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
    playUiSound('confirm')
    startEmerge(spawnData)

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
        backgroundColor = backgroundColor,
        uiConfig = oxLibUiConfig,
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
    -- #RRGGBB ou #RRGGBBAA (o alpha e ignorado no theming HSL da NUI)
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

-- Garante que NUI focus, câmera e estado do ped são restaurados se o recurso
-- for reiniciado/parado enquanto a UI estava aberta. Sem isso o jogador fica
-- travado (frozen, invisível) e sem input de teclado indefinidamente.
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
    FreezeEntityPosition(cache.ped, false)
    SetEntityInvincible(cache.ped, false)
    SetEntityVisible(cache.ped, true, false)
end)

