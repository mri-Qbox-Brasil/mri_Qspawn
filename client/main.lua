local Arrival = require 'client.arrival'
local spawns = {}

-- Runtime cache do config persistido em data/config.json. Hydratado lazy no
-- primeiro uso via lib.callback e mutado in-place pelo broadcast
-- `mri_Qspawn:client:configChanged` (admin salvou pela UI). Nunca leia direto
-- desta tabela antes da hidratacao terminar: chame ensureConfig() antes.
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
-- Em thread: o await no corpo do arquivo segurava o registro dos
-- RegisterNUICallback abaixo, e o nuiReady do React voltava 404.
CreateThread(fetchOxLibUiConfig)

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

-- Medição do spawn: mesmo relógio e prefixo do marco zero do mri_Qmultichar
-- (personagem escolhido), pra somar o tempo até o jogador ter controle.
local function markTime(step)
    debug(('[tempo-spawn] %s t=%d'):format(step, GetGameTimer()))
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

local isNuiOpen = false
local previewCam = nil
local selectedSpawn = nil
local hasJsSignaledReady = false -- ack-only: marca que o JS realmente confirmou recepcao
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

---@param blendMs number|nil duracao do blend de volta pra camera do jogo.
--- Use 0 quando outra script cam vai assumir logo em seguida (o blend de 1s
--- so faz sentido quando devolvemos o controle pro jogador de verdade).
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
-- Dispara o carregamento do MLO nessas coords, sem esperar. Separado da espera
-- de proposito: o streamAround chama isto no inicio pra o interior streamar
-- DURANTE a espera da cena, em vez de comecar a contar depois dela. Antes os
-- dois tetos (1500ms da cena + 3000ms do interior) se somavam.
-- `LoadInterior` e idempotente, entao chamar de novo no resolveGroundZ e barato.
local function beginInteriorLoad(x, y, z)
    local interior = GetInteriorAtCoords(x, y, z)
    if interior == 0 then return 0 end
    LoadInterior(interior)
    return interior
end

-- Espera o MLO ficar pronto, com teto. 1200ms e suficiente porque o
-- streamAround ja pediu o carregamento antes; estourando, o custo e ver o
-- interior montando por um instante — nao mais o Z errado (ver resolveGroundZ).
local function waitInteriorReady(interior, timeoutMs)
    if interior == 0 then return false end
    local deadline = GetGameTimer() + (timeoutMs or 1200)
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
    -- A PRESENCA do interior decide, nao o fato de ele ter terminado de
    -- carregar: dentro de MLO o floor e proprio e o Z do config manda. Antes,
    -- um interior que estourasse o teto caia no GetGroundZFor_3dCoord abaixo,
    -- que devolve o chao EXTERNO — o ped ia parar na rua embaixo do predio.
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

-- Teleporta o ped (congelado/invencível) pra coord. `visible` controla se ele
-- aparece: na seleção fica invisível (a câmera está nos olhos dele).
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
    -- Pede o MLO junto, sem esperar: ele streama durante o loop abaixo em vez
    -- de so comecar quando o resolveGroundZ chamar. E o que tira os ~3s de
    -- quem desloga dentro de apartamento/casa.
    beginInteriorLoad(x, y, z)
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

    ensureConfig() -- garante config hidratado (postfx/câmera dependem dele)

    isNuiOpen = true
    hasJsSignaledReady = false

    managePlayer()
    setCustomHudHidden(true) -- esconde a HUD do servidor enquanto seleciona o spawn

    local fx, fy, fz, fw = getCoordsValues(spawns[1].coords)
    if not (fx and fy and fz) then
        local pedPos = GetEntityCoords(cache.ped)
        fx, fy, fz, fw = pedPos.x, pedPos.y, pedPos.z, GetEntityHeading(cache.ped)
    end

    -- Vindo do multichar a tela ja esta preta; refazer o fade so custa 150ms.
    if not IsScreenFadedOut() then
        DoScreenFadeOut(150)
        while not IsScreenFadedOut() do Wait(0) end
    end

    -- Carrega o mundo no primeiro local antes de revelar.
    streamAround(fx, fy, fz, (config.blink and config.blink.stream) or 1500)
    markTime('cena carregada')

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
    hideGameHudWhileOpen()
    startCameraLoop()

    -- Segura antes do fade-in pra câmera renderizar o primeiro frame da chegada.
    Wait(200)
    DoScreenFadeIn(400)
    while IsScreenFadingIn() do Wait(0) end
    markTime('selecao visivel')

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
                    sendOpenMessage()
                    break
                end
                Wait(100)
            end
        end)
    end
end

-- Idempotente: chamado pelo nuiReady (JS confirma mount) e pelo fallback de
-- 8s. So bloqueia re-envio depois que o JS ack via nuiReady; o fallback nao
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

    markTime('ui aberta')

    if #spawns > 0 then
        selectedSpawn = spawns[1]
    end
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
-- Avisa a NUI qual local a câmera mostra de fato: o nome na tela troca junto
-- com a imagem, não no aperto da tecla.
local function notifyShown(index)
    SendNUIMessage({ action = 'locationShown', index = index })
end

---@param index number índice do spawn na NUI (base 0)
requestShowLocation = function(coords, index)
    if cam.mode ~= 'presence' then return end
    local x, y, z, w = getCoordsValues(coords)
    if not (x and y and z) then return end
    -- Piscando: o último pedido substitui o pendente. A checagem de "já está
    -- aqui" fica pra quando ele rodar (voltar pro local atual cancela o pendente).
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

-- Revela o personagem no mundo: com a chegada ligada ele se materializa e o
-- pulso sai dos pés dele (client/arrival.lua); desligada, só aparece.
---@param feet vector3
local function arrive(feet)
    if not config.arrival.enabled then
        SetEntityVisible(cache.ped, true, false)
        return
    end
    Arrival.materialize(cache.ped)
    Arrival.pulse(feet, accentColor:sub(1, 7), config.sound.enabled ~= false)
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

    requestShowLocation(spawnData.coords, data.index)
    cb({ success = true })
end)

-- O ps-housing so monta os imoveis no client no OnPlayerLoaded e avisa com
-- initialisedProperties; entrar antes disso quebra o EnterShell dele. Se o
-- player ja esta logado (relog ou restart deste resource), ja foram montados.
local housingReady = LocalPlayer.state.isLoggedIn == true
AddEventHandler('ps-housing:client:initialisedProperties', function()
    housingReady = true
end)

-- Sem 'spawn': o ps-housing entra pelo PlayerEnter (bucket e metadata inside),
-- igual a entrar pela porta.
local function enterProperty(propertyId)
    if GetResourceState('ps-housing') ~= 'started' then return end
    local deadline = GetGameTimer() + 10000
    while not housingReady and GetGameTimer() < deadline do Wait(50) end
    if not housingReady then
        print('[mri_Qspawn] AVISO: ps-housing nao carregou os imoveis; entrada no imovel cancelada.')
        return
    end
    -- Bucket 0 antes: o ps-housing troca pro bucket da casa (MLO fica no 0).
    if GetResourceState('mri_Qmultichar'):find('start') then
        TriggerServerEvent('mri_Qmultichar:server:setBucket', 0)
    end
    TriggerServerEvent('ps-housing:server:enterProperty', tostring(propertyId))
end

-- Dispara os eventos de carga do player (OnPlayerLoaded + housing). Ideal com o
-- ped ESCONDIDO: o reapply de aparência (illenium) fica oculto.
local function triggerSpawnLoad(spawnInfo)
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
    TriggerEvent('QBCore:Client:OnPlayerLoaded')
    if spawnInfo.propertyId then
        enterProperty(spawnInfo.propertyId)
    end
end

-- True se o spawn cai dentro de uma propriedade (housing assume câmera/teleporte,
-- então usamos fade em vez do "nascimento" cinematográfico).
local function spawnEntersProperty(spawnInfo)
    return spawnInfo.propertyId ~= nil
end

local function finishSpawn(insideProperty)
    -- Dentro de imovel o bucket e o da casa (ps-housing); voltar pro 0 tiraria a instancia.
    if not insideProperty and GetResourceState('mri_Qmultichar'):find('start') then
        TriggerServerEvent('mri_Qmultichar:server:setBucket', 0)
    end
    TriggerServerEvent('qbx_spawn:server:spawn')
    markTime('controle entregue')
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
            finishSpawn(true)
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

-- selectOnFirstSpawn: o personagem ja spawnou nesta sessao do servidor, entao
-- nasce direto no spawn (a ultima localizacao), sem abrir a selecao. Sincrono:
-- o chooseSpawn so retorna depois do spawn. A tela ja vem preta do multichar.
local function spawnWithoutSelection(spawnData)
    if not IsScreenFadedOut() then
        DoScreenFadeOut(150)
        while not IsScreenFadedOut() do Wait(0) end
    end

    local insideProperty = spawnEntersProperty(spawnData)
    local feet
    if not insideProperty then
        -- Dentro de imovel o ps-housing faz o teleporte (ver triggerSpawnLoad).
        -- Fora, o ped fica escondido ate a chegada revelar ele no fade-in.
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
    markTime('spawn confirmado')
    startEmerge(spawnData)

    cb({ success = true })
end)


-- Cache dos spawns que vêm do banco via callback. Refrescado a cada
-- chooseSpawn pra refletir alterações feitas pelo painel admin.
local cachedDataSpawns = nil
local function fetchDataSpawns()
    local ok, list = pcall(function()
        return lib.callback.await('mri_Qspawn:server:getSpawns', false)
    end)
    cachedDataSpawns = (ok and type(list) == 'table') and list or {}
    return cachedDataSpawns
end

-- "Última localização" só existe quando o personagem tem posição salva. Sem
-- ela, o primeiro spawn do painel abre a lista com o nome real dele (em vez de
-- se passar pela última localização); sem nenhum spawn no painel, o centro da
-- cidade garante um lugar pra nascer.
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
    addLastLocation(opts.fallback)
    addConfigSpawns()
    addHouses()
end

local function setupSpawnsInternal(citizenid)
    loadSpawns({ fallback = true })
    debug(string.format('[mri_Qspawn] %d spawns configurados', #spawns))
end

-- Entrypoint do qbx_core (multichar → "Play").
exports('chooseSpawn', function(citizenid)
    debug(string.format('[mri_Qspawn] chooseSpawn chamado com citizenid: %s', citizenid or 'nil'))
    markTime('chooseSpawn')

    if isNuiOpen then
        print('[mri_Qspawn] AVISO: UI já está aberta, ignorando chooseSpawn')
        return
    end

    SetNuiFocus(false, false) -- multichar pode deixar a NUI focada.

    -- Sem espera fixa aqui: a tela ja vem preta de quem chamou (multichar), e o
    -- openSpawnUI logo abaixo garante o fade antes de mexer na cena. Os 300ms +
    -- 200ms que havia eram chute — nao aguardavam nada verificavel.
    if previewCam and DoesCamExist(previewCam) then
        stopCamera(0) -- o createCam do openSpawnUI assume a seguir
    end

    selectedSpawn = nil

    setupSpawnsInternal(citizenid)
    markTime('spawns carregados')

    if #spawns == 0 then
        print('[mri_Qspawn] ERRO: Nenhum spawn foi configurado após setupSpawnsInternal!')
        return
    end

    -- spawns[1] e a ultima localizacao quando ela existe; senao, o primeiro local
    -- da lista (ver addLastLocation).
    ensureConfig()
    if config.selectOnFirstSpawn and lib.callback.await('qbx_spawn:server:alreadySpawned', false) then
        debug('[mri_Qspawn] Ja spawnou nesta sessao; indo direto pra ultima localizacao.')
        spawnWithoutSelection(spawns[1])
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
    -- que o React receba. Idempotente do lado JS: receber `open` 2x ok.
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
        id = data.id,
        spawn = data.spawn,
    })
    if ok then cachedDataSpawns = list end
    cb({ success = ok == true, spawns = list or cachedDataSpawns or {} })
end)

RegisterNUICallback('adminDeleteSpawn', function(data, cb)
    local ok, list = lib.callback.await('mri_Qspawn:server:deleteSpawn', false, data.id)
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

