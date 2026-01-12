local config = require 'config.client'
local spawns = {}

local isNuiOpen = false
local previewCam = nil
local scaleform = nil
local selectedSpawn = nil -- Armazenar o spawn selecionado
local selectedSpawnIndex = nil -- Índice do spawn selecionado para o mapa
local previousSelectedSpawn = nil -- Armazenar o spawn anterior (para usar como ponto de partida da animação)
local previousSelectedSpawnIndex = nil -- Índice do spawn anterior
local initialCameraPosition = nil -- Armazenar a posição inicial da câmera (last_location)

-- Controle de animações da câmera
local cameraAnimationThread = nil
local isCameraAnimating = false
local cameraDriftThread = nil -- Thread para micro-movimentos (drift)

-- Função para extrair coordenadas de diferentes formatos (declarada antes para ser usada em setupAerialMap)
local function getCoordsValues(coords)
    if not coords then return nil, nil, nil, nil end
    
    local x, y, z, w
    
    -- Formato com propriedades nomeadas
    if coords.x and coords.y and coords.z then
        x = tonumber(coords.x) or coords.x
        y = tonumber(coords.y) or coords.y
        z = tonumber(coords.z) or coords.z
        w = coords.w and (tonumber(coords.w) or coords.w) or nil
        return x, y, z, w
    end
    
    -- Formato com índices numéricos
    if coords[1] and coords[2] and coords[3] then
        x = tonumber(coords[1]) or coords[1]
        y = tonumber(coords[2]) or coords[2]
        z = tonumber(coords[3]) or coords[3]
        w = coords[4] and (tonumber(coords[4]) or coords[4]) or nil
        return x, y, z, w
    end
    
    return nil, nil, nil, nil
end

-- Função para calcular altura do chão em um ponto (aproximação simples)
local function getGroundZAtPoint(x, y, z)
    local found, groundZ = GetGroundZFor_3dCoord(x, y, z or 100.0, false)
    if found then
        return groundZ
    end
    -- Fallback: tentar várias alturas
    for testZ = 0, 200, 10 do
        found, groundZ = GetGroundZFor_3dCoord(x, y, testZ, false)
        if found then
            return groundZ
        end
    end
    return z or 0.0
end

-- Função para calcular altura padrão da câmera baseada no chão
local function calculatePreviewHeight(groundX, groundY, groundZ)
    local previewHeight = config.previewHeight or 45.0
    return groundZ + previewHeight
end

-- Função para parar drift da câmera
local function stopCameraDrift()
    if cameraDriftThread then
        cameraDriftThread = nil
    end
end

-- Função para iniciar micro-movimentos (drift) da câmera após enquadramento
local function startCameraDrift()
    stopCameraDrift() -- Parar qualquer drift anterior
    
    if not previewCam or not DoesCamExist(previewCam) then
        return
    end
    
    local driftIntensity = config.cameraDriftIntensity or 0.15
    if driftIntensity <= 0.0 then
        return -- Drift desabilitado
    end
    
    cameraDriftThread = CreateThread(function()
        local timer = 0.0
        
        -- Valores para movimento suave (variação sutil)
        -- IMPORTANTE: Não incluir yaw - o mapa deve sempre ficar "em pé", sem rotação
        local timeOffsetX = math.random() * 100.0
        local timeOffsetY = math.random() * 100.0
        
        while cameraDriftThread and DoesCamExist(previewCam) and isNuiOpen do
            timer = timer + GetFrameTime()
            
            if not isCameraAnimating then
                -- Movimento senoidal suave (quase imperceptível) - apenas X, Y e Z
                -- SEM rotação (yaw sempre fixo em 0.0)
                local offsetX = math.sin(timer * 0.3 + timeOffsetX) * driftIntensity * 0.5
                local offsetY = math.cos(timer * 0.25 + timeOffsetY) * driftIntensity * 0.5
                local offsetZ = math.sin(timer * 0.2) * driftIntensity * 0.3
                
                -- Obter posição atual
                local currentX, currentY, currentZ = GetCamCoord(previewCam)
                
                if currentX and currentY and currentZ then
                    -- Aplicar micro-movimentos apenas na posição (X, Y, Z)
                    SetCamCoord(previewCam, currentX + offsetX, currentY + offsetY, currentZ + offsetZ)
                    -- IMPORTANTE: Rotação sempre fixa: pitch -90° (satélite), roll 0°, yaw 0° (mapa sempre "em pé")
                    SetCamRot(previewCam, -90.0, 0.0, 0.0, 2)
                end
            end
            
            Wait(0)
        end
    end)
end

-- Função para configurar câmera de visualização aérea (sempre visão satélite)
local function setupAerialCamera(initialCoords)
    local startX, startY, groundZ
    local previewPitch = -90.0  -- Sempre visão satélite (olhando diretamente para baixo)
    local previewFov = config.previewFov or 60.0
    
    -- Se coordenadas iniciais foram fornecidas, usar elas (normalmente last location)
    if initialCoords then
        local x, y, z = getCoordsValues(initialCoords)
        if x and y and z then
            startX, startY = x, y
            groundZ = getGroundZAtPoint(x, y, z)
            print(string.format('[mri_Qspawn] Câmera inicializando na last location: %.2f, %.2f, %.2f (chão: %.2f)', x, y, z, groundZ))
        end
    end
    
    -- Se não conseguiu obter coordenadas iniciais, procurar last_location nos spawns
    if not startX or not startY then
        for i = 1, #spawns do
            if spawns[i] and spawns[i].label == 'last_location' and spawns[i].coords then
                local x, y, z = getCoordsValues(spawns[i].coords)
                if x and y and z then
                    startX, startY = x, y
                    groundZ = getGroundZAtPoint(x, y, z)
                    print(string.format('[mri_Qspawn] Câmera inicializando na last location encontrada: %.2f, %.2f, %.2f (chão: %.2f)', x, y, z, groundZ))
                    break
                end
            end
        end
    end
    
    -- Fallback: centro da cidade se não encontrou last location
    if not startX or not startY then
        startX, startY = -600.0, -50.0  -- Centro aproximado do mapa de Los Santos
        groundZ = getGroundZAtPoint(startX, startY, 30.0)
        print(string.format('[mri_Qspawn] Câmera inicializando no centro da cidade (fallback) - chão: %.2f', groundZ))
    end
    
    local startZ = calculatePreviewHeight(startX, startY, groundZ)
    
    -- IMPORTANTE: Armazenar a posição inicial da câmera (onde ela foi inicializada na last_location)
    -- Esta será sempre usada como ponto de partida quando não há spawn anterior selecionado
    initialCameraPosition = { x = startX, y = startY, z = startZ }
    print(string.format('[mri_Qspawn] Posição inicial da câmera armazenada: (%.2f, %.2f, %.2f)', startX, startY, startZ))
    
    previewCam = CreateCamWithParams(
        'DEFAULT_SCRIPTED_CAMERA',
        startX, startY, startZ,
        previewPitch, 0.0, 0.0,  -- Sempre visão satélite (-90°)
        previewFov,
        false,
        2
    )
    
    SetCamActive(previewCam, true)
    RenderScriptCams(true, true, 1000, true, true)
    
    -- Iniciar micro-movimentos (drift) da câmera
    startCameraDrift()
end

-- Função para cancelar animação em andamento
local function cancelCameraAnimation()
    if isCameraAnimating and cameraAnimationThread then
        isCameraAnimating = false
        cameraAnimationThread = nil
        print('[mri_Qspawn] Animação da câmera cancelada')
    end
end

-- Função para parar câmera
local function stopCamera()
    cancelCameraAnimation()
    stopCameraDrift()
    
    if previewCam and DoesCamExist(previewCam) then
        SetCamActive(previewCam, false)
        RenderScriptCams(false, true, 1000, true, true)
        DestroyCam(previewCam, true)
        previewCam = nil
    end
    
    if scaleform then
        BeginScaleformMovieMethod(scaleform, 'CLEANUP')
        EndScaleformMovieMethod()
        SetScaleformMovieAsNoLongerNeeded(scaleform)
        scaleform = nil
    end
end

-- Função para obter tipo de marcador e cor baseado no tipo de ícone
-- Usa diferentes tipos de marcadores para criar formas diferentes (similar aos ícones do menu)
local function getMarkerConfig(iconType)
    -- Retornar tipo de marcador, cor e forma baseado no ícone
    -- Tipo 1 = cilindro vertical, Tipo 2 = seta para cima, Tipo 3 = flecha, Tipo 28 = cilindro fino, etc.
    local markerConfig = {
        ['shield'] = { type = 2, r = 96, g = 165, b = 250 }, -- Azul, seta (shield/police)
        ['leaf'] = { type = 1, r = 52, g = 211, b = 153 }, -- Verde, cilindro (natureza)
        ['umbrella'] = { type = 3, r = 251, g = 191, b = 36 }, -- Amarelo, flecha (praia)
        ['bed'] = { type = 28, r = 167, g = 139, b = 250 }, -- Roxo, cilindro fino (motel)
        ['home'] = { type = 1, r = 251, g = 146, b = 60 }, -- Laranja, cilindro (casa)
        ['building'] = { type = 2, r = 34, g = 211, b = 238 }, -- Ciano, seta (edifício)
        ['map-pin'] = { type = 1, r = 251, g = 113, b = 133 } -- Rosa, cilindro (padrão)
    }
    return markerConfig[iconType] or markerConfig['map-pin']
end

-- Thread para renderizar TODOS os marcadores no mapa
local markerThread = nil
local lastValidIconPositions = {} -- Armazenar últimas posições válidas por índice

local function startMarkerThread()
    if markerThread then return end -- Já está rodando
    
    markerThread = CreateThread(function()
        while isNuiOpen do
            -- Renderizar TODOS os spawns no mapa
            local allIcons = {}
            
            for i = 1, #spawns do
                local spawn = spawns[i]
                if spawn and spawn.coords then
                    local x, y, z = getCoordsValues(spawn.coords)
                    if x and y and z then
                        local markerConfig = getMarkerConfig(spawn.icon or 'map-pin')
                        
                        -- Converter coordenadas 3D para 2D da tela
                        local iconOnScreen, icon_x, icon_y = World3dToScreen2d(x, y, z + 1.0)
                        
                        -- Só adicionar ícone se estiver na tela (iconOnScreen = true) e com coordenadas válidas
                        -- Validar que as coordenadas estão dentro dos limites (0.0 a 1.0)
                        if iconOnScreen and icon_x and icon_y and icon_x >= 0.0 and icon_x <= 1.0 and icon_y >= 0.0 and icon_y <= 1.0 then
                            local xPos = math.max(0.0, math.min(1.0, icon_x))
                            local yPos = math.max(0.0, math.min(1.0, icon_y))
                            
                            -- Armazenar última posição válida para este índice
                            lastValidIconPositions[i] = { x = xPos, y = yPos }
                            
                            -- Adicionar ícone ao array apenas se estiver visível na tela
                            allIcons[#allIcons + 1] = {
                                x = xPos,
                                y = yPos,
                                icon = spawn.icon or 'map-pin',
                                label = spawn.label == 'last_location' and 'Last Location' or (spawn.label or 'Location'),
                                iconColor = markerConfig.r .. ',' .. markerConfig.g .. ',' .. markerConfig.b
                            }
                        end
                        -- Se não está na tela, não adicionar ao array (não usar posição padrão para evitar aparecer no canto)
                    end
                end
            end
            
            -- Enviar todos os ícones de uma vez para React
            SendNUIMessage({
                action = 'updateMapIcon',
                allIcons = allIcons
            })
            
            Wait(0) -- Verificar a cada frame para posição precisa
        end
        markerThread = nil
    end)
end

local function stopMarkerThread()
    markerThread = nil
    -- Limpar todas as posições
    lastValidIconPositions = {}
    -- Ocultar todos os ícones
    SendNUIMessage({
        action = 'updateMapIcon',
        allIcons = {}
    })
end

local function updateMapMarker(spawnIndex)
    -- Não precisa mais fazer nada aqui, a thread renderiza todos automaticamente
    -- Mas vamos garantir que a thread está rodando
    if not markerThread then
        startMarkerThread()
    end
end

-- Função para configurar o mapa aéreo (renderizar minimap expandido)
local function setupAerialMap()
    CreateThread(function()
        -- Renderizar minimap expandido enquanto a NUI estiver aberta
            while isNuiOpen and DoesCamExist(previewCam) do
            -- Esconder componentes do HUD
            HideHudComponentThisFrame(6) -- Vehicle Name
            HideHudComponentThisFrame(7) -- Area Name
            HideHudComponentThisFrame(9) -- Vehicle Class
                
                Wait(0)
            end
        end)
end

-- Função para gerenciar o player durante seleção de spawn
local function managePlayer()
    -- Posicionar player em localização neutra (subsolo)
    SetEntityCoords(cache.ped, -21.58, -583.76, -100.0, false, false, false, false)
    FreezeEntityPosition(cache.ped, true)
    SetEntityInvincible(cache.ped, true)
    SetEntityVisible(cache.ped, false, false)
    
    SetTimeout(500, function()
        DoScreenFadeIn(5000)
    end)
end

-- Função para converter coords para formato JSON
local function serializeCoords(coords)
    if not coords then 
        print('[mri_Qspawn] serializeCoords: coords é nil')
        return nil 
    end
    
    local result = {}
    local x, y, z, w
    
    -- Tentar extrair x, y, z, w de diferentes formatos
    -- vec4/vector4 normalmente tem propriedades .x, .y, .z, .w
    local success1, val = pcall(function() return coords.x end)
    if success1 and val ~= nil then
        x = tonumber(val)
        local success2, val2 = pcall(function() return coords.y end)
        if success2 and val2 ~= nil then
            y = tonumber(val2)
            local success3, val3 = pcall(function() return coords.z end)
            if success3 and val3 ~= nil then
                z = tonumber(val3)
                
                -- Tentar obter w/heading
                local success4, val4 = pcall(function() return coords.w end)
                if success4 and val4 ~= nil then
                    w = tonumber(val4)
                else
                    local success5, val5 = pcall(function() return coords[4] end)
                    if success5 and val5 ~= nil then
                        w = tonumber(val5)
                    end
                end
                
                if x and y and z then
                    result.x = x
                    result.y = y
                    result.z = z
                    if w then result.w = w end
                    return result
                end
            end
        end
    end
    
    -- Formato com índices numéricos [1], [2], [3], [4]
    local success_idx, val1 = pcall(function() return coords[1] end)
    if success_idx and val1 ~= nil then
        x = tonumber(val1)
        local success2_idx, val2 = pcall(function() return coords[2] end)
        if success2_idx and val2 ~= nil then
            y = tonumber(val2)
            local success3_idx, val3 = pcall(function() return coords[3] end)
            if success3_idx and val3 ~= nil then
                z = tonumber(val3)
                local success4_idx, val4 = pcall(function() return coords[4] end)
                if success4_idx and val4 ~= nil then
                    w = tonumber(val4)
                end
                
                if x and y and z then
                    result.x = x
                    result.y = y
                    result.z = z
                    if w then result.w = w end
                    return result
                end
            end
        end
    end
    
    -- Última tentativa: verificar se é uma string que precisa ser parseada
    if type(coords) == 'string' then
        local success, parsed = pcall(function() return json.decode(coords) end)
        if success and parsed then
            return serializeCoords(parsed) -- Recursivamente tentar novamente
        end
    end
    
    print('[mri_Qspawn] serializeCoords: Não foi possível extrair coordenadas. Tipo:', type(coords))
    if type(coords) == 'table' then
        print('[mri_Qspawn] Tabela keys:', json.encode(coords))
    end
    return nil
end

-- Função para serializar spawns para enviar à NUI
local function serializeSpawns(spawnsToSerialize)
    if not spawnsToSerialize or #spawnsToSerialize == 0 then
        print('[mri_Qspawn] Nenhum spawn para serializar')
        return {}
    end
    
    local serialized = {}
    for i = 1, #spawnsToSerialize do
        local spawn = spawnsToSerialize[i]
        if not spawn then
            print(string.format('[mri_Qspawn] Spawn %d é nil', i))
            goto continue
        end
        
        local serializedCoords = serializeCoords(spawn.coords)
        if not serializedCoords then
            print(string.format('[mri_Qspawn] Spawn %d (%s) não tem coordenadas válidas', i, spawn.label or 'sem label'))
            goto continue
        end
        
        local serializedSpawn = {
            label = spawn.label,
            coords = serializedCoords,
            icon = spawn.icon,
            description = spawn.description,
            propertyId = spawn.propertyId,
            first_time = spawn.first_time,
            key = spawn.key
        }
        serialized[#serialized + 1] = serializedSpawn
        
        ::continue::
    end
    
    print(string.format('[mri_Qspawn] Serializados %d spawns de %d totais', #serialized, #spawnsToSerialize))
    return serialized
end

-- Função para abrir a NUI
local function openSpawnUI()
    if isNuiOpen then 
        print('[mri_Qspawn] AVISO: Tentativa de abrir UI quando já está aberta!')
        return 
    end
    
    print(string.format('[mri_Qspawn] Abrindo UI com %d spawns disponíveis', #spawns))
    
    if #spawns == 0 then
        print('[mri_Qspawn] ERRO: Nenhum spawn disponível!')
        return
    end
    
    -- Procurar last_location para usar como posição inicial da câmera
    local initialCoords = nil
    for i = 1, #spawns do
        if spawns[i] and spawns[i].label == 'last_location' and spawns[i].coords then
            initialCoords = spawns[i].coords
            print('[mri_Qspawn] Last location encontrada, usando como posição inicial da câmera')
            break
        end
    end
    
    -- Se não encontrou last_location, usar o primeiro spawn como fallback
    if not initialCoords and #spawns > 0 and spawns[1] and spawns[1].coords then
        initialCoords = spawns[1].coords
        print('[mri_Qspawn] Usando primeiro spawn como posição inicial da câmera')
    end
    
    -- Verificar se há coordenadas iniciais válidas
    if not initialCoords then
        print('[mri_Qspawn] ERRO: Não foi possível determinar coordenadas iniciais para a câmera!')
        return
    end
    
    -- Garantir que NUI focus anterior foi fechado (do multichar)
    SetNuiFocus(false, false)
    Wait(100) -- Pequeno delay para garantir que o foco anterior foi liberado
    
    -- Marcar UI como aberta ANTES de configurar câmera (para evitar loops)
    isNuiOpen = true
    
    -- Gerenciar player (esconder, congelar, etc)
    managePlayer()
    
    -- Configurar câmera aérea com coordenadas iniciais
    print('[mri_Qspawn] Configurando câmera aérea...')
    setupAerialCamera(initialCoords)
    
    -- Configurar mapa aéreo
    print('[mri_Qspawn] Configurando mapa aéreo...')
    setupAerialMap()
    
    -- Aguardar um pouco para garantir que a câmera e o mapa estão prontos
    Wait(400)
    
    -- Definir foco na NUI
    SetNuiFocus(true, true)
    print('[mri_Qspawn] Foco da NUI ativado')
    
    -- Serializar spawns antes de enviar
    local serializedSpawns = serializeSpawns(spawns)
    
    print(string.format('[mri_Qspawn] Enviando %d spawns serializados para a NUI', #serializedSpawns))
    
    if #serializedSpawns == 0 then
        print('[mri_Qspawn] ERRO: Nenhum spawn serializado para enviar!')
        closeSpawnUI()
        return
    end
    
    -- Enviar mensagem para a NUI
    SendNUIMessage({
        action = 'open',
        spawns = serializedSpawns,
    })
    
    -- Selecionar automaticamente o primeiro spawn (last_location)
    if #spawns > 0 and spawns[1] then
        selectedSpawn = spawns[1]
        selectedSpawnIndex = 1
        print(string.format('[mri_Qspawn] Selecionando automaticamente: %s (índice 1)', spawns[1].label or 'last_location'))
        -- Iniciar thread para renderizar todos os ícones no mapa
        CreateThread(function()
            Wait(300) -- Delay mínimo apenas para garantir que a câmera está ativa
            if isNuiOpen then
                -- Iniciar thread que renderiza TODOS os spawns no mapa
                startMarkerThread()
            end
        end)
    end
    
    print('[mri_Qspawn] UI aberta com sucesso!')
end

-- Função para fechar a NUI
local function closeSpawnUI()
    if not isNuiOpen then return end
    
    isNuiOpen = false
    selectedSpawn = nil
    selectedSpawnIndex = nil
    previousSelectedSpawn = nil
    previousSelectedSpawnIndex = nil
    stopMarkerThread()
    SetNuiFocus(false, false)
    stopCamera()
    
    SendNUIMessage({
        action = 'close',
    })
end


-- Função para mover a câmera até a localização (movimento horizontal tipo drone - mesma altura)
local function moveCameraToLocation(coords, duration)
    if not previewCam or not DoesCamExist(previewCam) then
        print('[mri_Qspawn] ERRO: Câmera não existe para moveCameraToLocation')
        return
    end
    
    local endX, endY, endZ = getCoordsValues(coords)
    if not endX or not endY or not endZ then
        print('[mri_Qspawn] ERRO: Coordenadas inválidas para moveCameraToLocation')
        return
    end
    
    -- Parar animação anterior suavemente (sem resetar a câmera)
    cancelCameraAnimation()
    stopCameraDrift()
    
    -- Aguardar um pouco para a thread anterior parar completamente (menos delay para transição mais rápida)
    Wait(50)
    
    -- IMPORTANTE: Usar a posição ATUAL da câmera como ponto de partida para transições suaves
    -- Isso evita resets ou "pulos" visuais
    local camX, camY, camZ = GetCamCoord(previewCam)
    local camRot = GetCamRot(previewCam, 2)
    local camPitch = camRot.x or -90.0
    local camRoll = camRot.y or 0.0
    local camYaw = camRot.z or 0.0
    
    -- Verificar se a posição da câmera é válida
    if not camX or not camY or not camZ or camX == 0.0 then
        -- Se a câmera não tem posição válida, usar spawn anterior ou last_location
        if previousSelectedSpawn and previousSelectedSpawn.coords and previousSelectedSpawnIndex then
            local prevX, prevY, prevZ = getCoordsValues(previousSelectedSpawn.coords)
            if prevX and prevY and prevZ then
                camX, camY = prevX, prevY
                local groundZ = getGroundZAtPoint(prevX, prevY, prevZ)
                camZ = calculatePreviewHeight(prevX, prevY, groundZ)
                camPitch = -90.0
                camRoll = 0.0
                camYaw = 0.0
            end
        end
        
        -- Se ainda não temos coordenadas válidas, usar last_location
        if not camX or camX == 0.0 then
            for i = 1, #spawns do
                if spawns[i] and spawns[i].label == 'last_location' and spawns[i].coords then
                    local lastX, lastY, lastZ = getCoordsValues(spawns[i].coords)
                    if lastX and lastY and lastZ then
                        camX, camY = lastX, lastY
                        local groundZ = getGroundZAtPoint(lastX, lastY, lastZ)
                        camZ = calculatePreviewHeight(lastX, lastY, groundZ)
                        camPitch = -90.0
                        camRoll = 0.0
                        camYaw = 0.0
                        break
                    end
                end
            end
        end
    else
        -- Garantir que a altura está dentro do esperado para evitar saltos
        local groundZStart = getGroundZAtPoint(camX, camY, camZ)
        local expectedHeight = calculatePreviewHeight(camX, camY, groundZStart)
        -- Se a altura está muito diferente, ajustar suavemente (mas manter a posição X,Y atual)
        if math.abs(camZ - expectedHeight) > 200.0 then
            camZ = expectedHeight
        end
        -- Manter rotação atual para transições mais suaves
        camPitch = camPitch or -90.0
        camRoll = camRoll or 0.0
        camYaw = camYaw or 0.0
    end
    
    -- Log para debug
    print(string.format('[mri_Qspawn] Posição inicial da câmera: (%.2f, %.2f, %.2f)', camX, camY, camZ))
    
    -- Calcular altura final baseada no chão do destino
    local groundZEnd = getGroundZAtPoint(endX, endY, endZ)
    local endHeight = calculatePreviewHeight(endX, endY, groundZEnd)
    
    -- Configurações de movimento horizontal (pan) - SEMPRE fazer animação tipo drone (MAXIMAMENTE SUAVE)
    local panSpeed = config.transitionPanSpeed or 0.25 -- metros por ms (extremamente lento para movimento muito suave)
    local panDurationBase = config.transitionPanDurationBase or 7000 -- mínimo 7000ms (movimento extremamente suave e lento tipo drone - 7 segundos)
    
    -- SEMPRE usar duração fixa para movimento tipo drone (independente de distância)
    -- Esta duração garante movimento muito suave, lento e visível sempre (sem cortes ou resets)
    local panDuration = panDurationBase
    
    local previewFov = config.previewFov or 60.0
    
    print(string.format('[mri_Qspawn] Movimento tipo drone: (%.2f, %.2f, %.2f) -> (%.2f, %.2f, %.2f) duração: %dms', 
        camX, camY, camZ, endX, endY, endHeight, math.floor(panDuration)))
    
    isCameraAnimating = true
    
    cameraAnimationThread = CreateThread(function()
        local totalStartTime = GetGameTimer()
        
        -- Aguardar um pouco antes de começar para garantir estabilidade (reduzido para transição mais rápida)
        Wait(50)
        
        -- IMPORTANTE: Usar SEMPRE a posição passada como parâmetro (que já foi calculada corretamente)
        -- Esta posição foi calculada baseada no spawn anterior OU last_location
        -- Não tentar obter novamente com GetCamCoord pois pode retornar posição errada e causar resets
        local startX, startY, startZ = camX, camY, camZ
        
        -- IMPORTANTE: Sempre manter yaw fixo em 0.0 (mapa sempre "em pé", sem rotação)
        -- A câmera apenas se move, mas nunca gira
        local fixedYaw = 0.0
        
        -- Calcular distância real entre ponto de partida e destino
        local distance = math.sqrt((endX - startX)^2 + (endY - startY)^2)
        
        print(string.format('[mri_Qspawn] Distância calculada: %.2fm de (%.2f, %.2f) para (%.2f, %.2f)', 
            distance, startX, startY, endX, endY))
        
        -- Se a distância for muito pequena ou zero, forçar uso da last_location como ponto de partida
        if distance < 5.0 then
            print('[mri_Qspawn] AVISO: Distância muito pequena ou zero, forçando uso da last_location como ponto de partida')
            for i = 1, #spawns do
                if spawns[i] and spawns[i].label == 'last_location' and spawns[i].coords then
                    local lastX, lastY, lastZ = getCoordsValues(spawns[i].coords)
                    if lastX and lastY and lastZ and (math.abs(lastX - endX) > 5.0 or math.abs(lastY - endY) > 5.0) then
                        startX, startY = lastX, lastY
                        local groundZ = getGroundZAtPoint(lastX, lastY, lastZ)
                        startZ = calculatePreviewHeight(lastX, lastY, groundZ)
                        distance = math.sqrt((endX - startX)^2 + (endY - startY)^2)
                        print(string.format('[mri_Qspawn] Ponto de partida ajustado para last_location: (%.2f, %.2f, %.2f), nova distância: %.2fm', 
                            startX, startY, startZ, distance))
                        break
                    end
                end
            end
        end
        
        -- Calcular altura final - manter mesma altura para movimento tipo drone
        local endHeight = startZ -- Mesma altura do início para movimento tipo drone
        
        -- SEMPRE usar duração fixa para movimento tipo drone (não calcular baseado em distância)
        -- Duração já foi definida como panDurationBase (7000ms) antes de entrar na thread para movimento extremamente suave
        print(string.format('[mri_Qspawn] Drone iniciando movimento MUITO suave: (%.2f, %.2f, %.2f) -> (%.2f, %.2f, %.2f) distância: %.2fm, duração: %dms', 
            startX, startY, startZ, endX, endY, endHeight, distance, math.floor(panDuration)))
        
        -- IMPORTANTE: NÃO calcular yaw - manter sempre fixo em 0.0 (mapa sempre "em pé")
        -- A câmera apenas se move horizontalmente, sem rotação
        
        -- Calcular ponto intermediário para curva suave (não linha reta rígida)
        local midX = (startX + endX) / 2.0
        local midY = (startY + endY) / 2.0
        -- Usar offset fixo se distância for muito pequena, senão usar percentual da distância
        local curveOffset = distance > 10.0 and math.min(distance * 0.2, 100.0) or 50.0 -- Offset mínimo de 50m para garantir curva visível
        local angle = math.atan2(endY - startY, endX - startX)
        local perpAngle = angle + math.pi / 2.0
        midX = midX + math.cos(perpAngle) * curveOffset
        midY = midY + math.sin(perpAngle) * curveOffset
        
        -- MOVIMENTO HORIZONTAL DIRETO (mesma altura, apenas X e Y mudam) - MAXIMAMENTE SUAVE E SEM CORTES
        local panStartTime = GetGameTimer()
        
        -- IMPORTANTE: Usar GetGameTimer dentro do loop para garantir cálculo preciso do progresso
        while GetGameTimer() - panStartTime < panDuration do
            if not DoesCamExist(previewCam) or not isCameraAnimating then break end
            
            local elapsed = GetGameTimer() - panStartTime
            local progress = elapsed / panDuration
            progress = math.min(progress, 1.0)
            
            -- Easing EXTREMAMENTE suave (ease in out cúbico mais suave) para movimento ultra fluido SEM CORTES ou RESETS
            -- Usar ease in out cúbico mais suave: início e fim muito suaves para transição perfeita
            local easeProgress = progress < 0.5
                and 4 * progress * progress * progress
                or 1 - math.pow(-2 * progress + 2, 3) / 2
            
            -- Interpolação quadrática (Bezier) para curva suave tipo drone
            local t = easeProgress
            local currentX = (1 - t) * (1 - t) * startX + 2 * (1 - t) * t * midX + t * t * endX
            local currentY = (1 - t) * (1 - t) * startY + 2 * (1 - t) * t * midY + t * t * endY
            
            -- MANTER MESMA ALTURA durante todo o movimento (como drone voando na mesma altitude)
            -- Usar altura atual da câmera, sem interpolação
            local currentZ = startZ
            
            -- IMPORTANTE: Manter yaw SEMPRE fixo em 0.0 (mapa sempre "em pé", sem rotação)
            -- A câmera apenas se move, mas NUNCA gira
            local currentYaw = fixedYaw -- Sempre 0.0, sem interpolação
            
            -- IMPORTANTE: Sempre atualizar câmera de forma suave e contínua (SEM cortes ou resets)
            -- Rotação sempre fixa: pitch -90° (satélite), roll 0°, yaw 0° (norte fixo)
            SetCamCoord(previewCam, currentX, currentY, currentZ)
            SetCamRot(previewCam, -90.0, 0.0, currentYaw, 2)
            SetCamFov(previewCam, previewFov)
            
            Wait(0)
        end
        
        if not DoesCamExist(previewCam) or not isCameraAnimating then
            isCameraAnimating = false
            return
        end
        
        -- IMPORTANTE: Garantir posição final exata de forma suave (sem cortes ou resets)
        -- O loop anterior já deixou a câmera na posição correta, apenas garantir valores exatos
        if DoesCamExist(previewCam) then
            SetCamCoord(previewCam, endX, endY, endHeight)
            -- IMPORTANTE: Yaw sempre fixo em 0.0 (mapa sempre "em pé", sem rotação)
            SetCamRot(previewCam, -90.0, 0.0, fixedYaw, 2)
            SetCamFov(previewCam, previewFov)
            
            -- Aguardar um frame para garantir que a posição final foi aplicada suavemente
            Wait(0)
        end
        
        isCameraAnimating = false
        cameraAnimationThread = nil
        
        -- Reiniciar drift da câmera de forma suave (após transição completa)
        Wait(50) -- Aguardar um pouco antes de reiniciar drift para garantir suavidade
        startCameraDrift()
        
        local totalDuration = GetGameTimer() - totalStartTime
        print(string.format('[mri_Qspawn] Movimento drone concluído suavemente em %dms (sem cortes ou resets)', totalDuration))
    end)
end

-- Função para fazer zoom da câmera até o jogador (da vista aérea até o chão)
local function zoomCameraToPlayer(coords, spawnData, duration, callback)
    duration = duration or (config.zoomDuration or 4000)
    
    if not previewCam or not DoesCamExist(previewCam) then
        print('[mri_Qspawn] ERRO: Câmera não existe para zoomCameraToPlayer')
        if callback then callback() end
        return
    end
    
    local endX, endY, endZ = getCoordsValues(coords)
    if not endX or not endY or not endZ then
        print('[mri_Qspawn] ERRO: Coordenadas inválidas para zoomCameraToPlayer')
        if callback then callback() end
        return
    end
    
    -- Obter coordenadas atuais da câmera
    local camX, camY, camZ = GetCamCoord(previewCam)
    if not camX or not camY or not camZ then
        -- Usar coordenadas finais como fallback
        camX, camY, camZ = endX, endY, config.aerialViewHeight or 700.0
        SetCamCoord(previewCam, camX, camY, camZ)
        SetCamRot(previewCam, -90.0, 0.0, 0.0, 2)
    end
    
    local startTime = GetGameTimer()
    local startX, startY, startZ = camX, camY, camZ
    local targetZ = endZ + 1.5 -- 1.5 metros acima do chão
    local hasSpawned = false
    
    CreateThread(function()
        while GetGameTimer() - startTime < duration do
            if not DoesCamExist(previewCam) then
                break
            end
            
            local elapsed = GetGameTimer() - startTime
            local progress = elapsed / duration
            progress = math.min(progress, 1.0)
            
            -- Easing function (ease in out cubic)
            local easeProgress = progress < 0.5
                and 4 * progress * progress * progress
                or 1 - math.pow(-2 * progress + 2, 3) / 2
            
            -- Interpolar posição X e Y (centrar na localização)
            local currentX = startX + (endX - startX) * easeProgress
            local currentY = startY + (endY - startY) * easeProgress
            
            -- Interpolar altura (de alto para baixo) - totalmente de cima para baixo
            local currentHeight = startZ - (startZ - targetZ) * easeProgress
            
            SetCamCoord(previewCam, currentX, currentY, currentHeight)
            
            -- Rotação totalmente de cima para baixo (mantém -90 até quase o final, depois inclina um pouco)
            local pitch
            if progress < 0.8 then
                -- Primeiros 80%: totalmente de cima (-90 graus olhando para baixo)
                pitch = -90.0
            else
                -- Últimos 20%: inclinar um pouco para ver o player melhor
                local finalProgress = (progress - 0.8) / 0.2
                pitch = -90.0 + (50.0 * finalProgress) -- De -90 para -40 graus
            end
            SetCamRot(previewCam, pitch, 0.0, 0.0, 2)
            
            -- Spawnar o player quando a câmera estiver próxima (70% do progresso)
            if not hasSpawned and progress >= 0.7 then
                hasSpawned = true
                local x, y, z, w = getCoordsValues(coords)
                if x and y and z then
                    -- Posicionar o player na localização (invisível ainda)
                    SetEntityCoords(cache.ped, x, y, z, false, false, false, false)
                    SetEntityHeading(cache.ped, w or 0.0)
                    FreezeEntityPosition(cache.ped, true)
                    SetEntityVisible(cache.ped, true, false)
                    SetEntityInvincible(cache.ped, true)
                    print('[mri_Qspawn] Player posicionado na localização durante o zoom')
                end
            end
            
            Wait(0)
        end
        
        -- Garantir que o player foi spawnado
        if not hasSpawned then
            local x, y, z, w = getCoordsValues(coords)
            if x and y and z then
                SetEntityCoords(cache.ped, x, y, z, false, false, false, false)
                SetEntityHeading(cache.ped, w or 0.0)
                FreezeEntityPosition(cache.ped, true)
                SetEntityVisible(cache.ped, true, false)
                SetEntityInvincible(cache.ped, true)
            end
        end
        
        -- Garantir posição final da câmera
        if DoesCamExist(previewCam) then
            SetCamCoord(previewCam, endX, endY, targetZ)
            SetCamRot(previewCam, -40.0, 0.0, 0.0, 2)
        end
        
        -- Chamar callback quando o zoom terminar
        if callback then
            callback(spawnData)
        end
    end)
end

-- Callback para obter spawns
RegisterNUICallback('getSpawns', function(_, cb)
    local serializedSpawns = serializeSpawns(spawns)
    cb({ success = true, spawns = serializedSpawns })
end)

-- Callback para selecionar spawn (apenas mover câmera, não spawnar)
RegisterNUICallback('selectSpawn', function(data, cb)
    local spawnIndex = data.index + 1 -- React usa índice 0, Lua usa 1
    if not spawnIndex or spawnIndex < 1 or spawnIndex > #spawns then
        cb({ success = false, message = 'Spawn inválido' })
        return
    end
    
    local spawnData = spawns[spawnIndex]
    
    if not spawnData or not spawnData.coords then
        cb({ success = false, message = 'Spawn sem coordenadas' })
        return
    end
    
    -- IMPORTANTE: Armazenar spawn ANTERIOR antes de atualizar selectedSpawn
    -- Isso permite usar a posição do spawn anterior como ponto de partida da animação
    previousSelectedSpawn = selectedSpawn
    previousSelectedSpawnIndex = selectedSpawnIndex
    
    -- Agora atualizar o spawn selecionado
    selectedSpawn = spawnData
    selectedSpawnIndex = spawnIndex
    
    print(string.format('[mri_Qspawn] Spawn selecionado: %s (índice %d)', spawnData.label or 'sem label', spawnIndex))
    if previousSelectedSpawn then
        print(string.format('[mri_Qspawn] Spawn anterior: %s (índice %d)', previousSelectedSpawn.label or 'sem label', previousSelectedSpawnIndex))
    else
        print('[mri_Qspawn] Sem spawn anterior, usando last_location como ponto de partida')
    end
    
    -- Atualizar marcador no mapa
    updateMapMarker(spawnIndex)
    
    -- Ocultar ícone durante a animação
    SendNUIMessage({
        action = 'updateMapIcon',
        visible = false
    })
    
    -- Apenas mover a câmera até a localização (sem spawnar)
    -- A função moveCameraToLocation usará previousSpawn ou last_location como ponto de partida
    moveCameraToLocation(spawnData.coords, 2000)
    
    cb({ success = true })
end)

-- Função para fazer uma animação simples ao spawnar
local function playSimpleSpawnAnimation()
    CreateThread(function()
        Wait(300) -- Aguardar um pouco
        
        local playerPed = PlayerPedId()
        if not playerPed or playerPed == 0 then
            return
        end
        
        -- Usar scenarios (mais confiáveis que animações diretas)
        local scenarios = {
            'WORLD_HUMAN_STAND_IMPATIENT',
            'WORLD_HUMAN_SMOKING',
            'WORLD_HUMAN_HANG_OUT_STREET'
        }
        
        local selectedScenario = scenarios[math.random(#scenarios)]
        TaskStartScenarioInPlace(playerPed, selectedScenario, 0, true)
        Wait(3000)
        ClearPedTasks(playerPed)
    end)
end

-- Callback para confirmar spawn (quando ENTER é pressionado)
RegisterNUICallback('confirmSpawn', function(_, cb)
    if not selectedSpawn or not selectedSpawn.coords then
        print('[mri_Qspawn] ERRO: Nenhum spawn selecionado ao confirmar')
        cb({ success = false, message = 'Nenhum spawn selecionado' })
        return
    end
    
    -- Armazenar dados do spawn antes de limpar (para usar no callback)
    local spawnData = {
        coords = selectedSpawn.coords,
        propertyId = selectedSpawn.propertyId,
        label = selectedSpawn.label
    }
    
    print(string.format('[mri_Qspawn] Confirmando spawn: %s', spawnData.label or 'sem label'))
    
    -- Fazer zoom da câmera até o local de spawn (player será spawnado durante o zoom quando próximo)
    zoomCameraToPlayer(spawnData.coords, spawnData, config.zoomDuration or 4000, function(spawnInfo)
        -- Callback executado quando o zoom terminar
        
        -- Fechar NUI antes de fazer fade
        closeSpawnUI()
        selectedSpawn = nil
        selectedSpawnIndex = nil
        
        -- Fade out simples
            DoScreenFadeOut(1000)
            while not IsScreenFadedOut() do
                Wait(0)
            end
        
        -- Desativar câmera scriptada suavemente antes de parar
        RenderScriptCams(false, true, 1000, true, true)
        
        -- Aguardar transição da câmera
        Wait(1000)
        
        -- Parar e destruir câmera
            stopCamera()
        
        -- Garantir que o player está visível e desbloqueado
        FreezeEntityPosition(cache.ped, false)
        SetEntityVisible(cache.ped, true, false)
        SetEntityInvincible(cache.ped, false)
        
        -- Verificar se é propriedade
        if spawnInfo and spawnInfo.propertyId then
            TriggerServerEvent('ps-housing:server:enterProperty', tostring(spawnInfo.propertyId), 'spawn')
        elseif spawnInfo and spawnInfo.label == 'last_location' then
            if QBX and QBX.PlayerData and QBX.PlayerData.metadata then
                local insideMeta = QBX.PlayerData.metadata["inside"]
                if insideMeta and insideMeta.property_id then
                    local property_id = insideMeta.property_id
                    TriggerServerEvent('ps-housing:server:enterProperty', tostring(property_id))
                end
            end
        end
        
        TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
        TriggerEvent('QBCore:Client:OnPlayerLoaded')
        
        -- Fade in - player já está posicionado
        DoScreenFadeIn(800)
        Wait(800)
        
        -- Animação simples (esperando ou fumando)
        playSimpleSpawnAnimation()
        
        -- Mudar para o bucket global (0)
        TriggerServerEvent('mri_Qmultichar:server:setBucket', 0)
        print('[mri_Qspawn] Player movido para o bucket global (0)')
        
        TriggerServerEvent('qbx_spawn:server:spawn')
        print('[mri_Qspawn] Spawn completado')
    end)
    
    cb({ success = true })
end)

-- Callback para fechar NUI
RegisterNUICallback('close', function(data, cb)
    local returnToMultichar = data and data.returnToMultichar or false
    closeSpawnUI()
    
    -- Se deve retornar ao multichar (quando ESC é pressionado)
    if returnToMultichar then
        -- Aguardar um pouco para garantir que a UI foi fechada completamente
        Wait(200)
        -- Retornar ao multichar
        if GetResourceState('mri_Qmultichar'):find('start') then
            exports['mri_Qmultichar']:openMultichar()
        else
            print('[mri_Qspawn] AVISO: Resource mri_Qmultichar não encontrado')
        end
    end
    
    cb({ success = true })
end)

-- Função interna para configurar spawns
local function setupSpawnsInternal(citizenid)
    spawns = {}
    
    -- SEMPRE tentar obter a última localização do servidor
    local lastLoc, propertyId
    local success = pcall(function()
        lastLoc, propertyId = lib.callback.await('qbx_spawn:server:getLastLocation', false)
    end)
    
    if not success then
        print('[mri_Qspawn] ERRO ao obter última localização do servidor')
        lastLoc = nil
        propertyId = nil
    end
    
    -- Verificar se a última localização é válida
    local hasValidLastLoc = lastLoc and lastLoc.x and lastLoc.y and lastLoc.z
    if hasValidLastLoc then
        -- Se a posição é a posição padrão (0, 0, 0) ou muito próxima, considerar inválida
        if (math.abs(lastLoc.x) < 1.0 and math.abs(lastLoc.y) < 1.0 and math.abs(lastLoc.z) < 1.0) then
            hasValidLastLoc = false
            print('[mri_Qspawn] Última localização inválida (posição padrão 0,0,0)')
        end
    end
    
    -- SEMPRE adicionar last_location como primeiro spawn (primeiro na lista)
    if hasValidLastLoc then
        -- Usar a última localização salva
        spawns[#spawns+1] = {
            label = 'last_location',
            coords = lastLoc,
            icon = 'map-pin',
            description = 'Start at last location',
            propertyId = propertyId
        }
        print(string.format('[mri_Qspawn] Adicionada última localização salva: %.2f, %.2f, %.2f', lastLoc.x, lastLoc.y, lastLoc.z))
    else
        -- Se não tem last location válida, usar o primeiro spawn do config como "last location"
        -- Isso garante que sempre haverá uma last_location para a câmera iniciar
        if config.spawns and #config.spawns > 0 and config.spawns[1] and config.spawns[1].coords then
            local spawn = config.spawns[1]
            local coords = spawn.coords
            local x, y, z, w
            
            if type(coords) == 'vector4' or (coords.x and coords.y and coords.z) then
                x = tonumber(coords.x) or coords.x
                y = tonumber(coords.y) or coords.y
                z = tonumber(coords.z) or coords.z
                w = coords.w and (tonumber(coords.w) or coords.w) or nil
            elseif type(coords) == 'table' and coords[1] and coords[2] and coords[3] then
                x = tonumber(coords[1]) or coords[1]
                y = tonumber(coords[2]) or coords[2]
                z = tonumber(coords[3]) or coords[3]
                w = coords[4] and (tonumber(coords[4]) or coords[4]) or nil
            else
                x, y, z, w = getCoordsValues(coords)
            end
            
            if x and y and z then
                spawns[#spawns+1] = {
                    label = 'last_location',
                    coords = { x = x, y = y, z = z, w = w },
                    icon = 'map-pin',
                    description = 'Start at last location',
                    propertyId = nil
                }
                print(string.format('[mri_Qspawn] Adicionada última localização padrão (usando primeiro spawn do config): %s (%.2f, %.2f, %.2f)', spawn.label or 'Location', x, y, z))
            end
        else
            -- Último recurso: usar uma posição padrão fixa
            spawns[#spawns+1] = {
                label = 'last_location',
                coords = { x = -269.4, y = -955.3, z = 31.2, w = 205.8 },
                icon = 'map-pin',
                description = 'Start at last location',
                propertyId = nil
            }
            print('[mri_Qspawn] Adicionada última localização padrão (posição fixa de emergência)')
        end
    end
    
    -- Agora adicionar os outros spawns (personagem existente mostra todos, novo também)
    print('[mri_Qspawn] Carregando spawns adicionais')
    
    -- Adicionar spawns do config (pular o primeiro se foi usado como last_location padrão)
    if config.spawns and #config.spawns > 0 then
        print(string.format('[mri_Qspawn] Carregando %d spawns do config', #config.spawns))
        local startIndex = 1
        
        -- Se usamos o primeiro spawn como last_location padrão, começar do segundo
        if not hasValidLastLoc and #config.spawns > 0 then
            startIndex = 2
        end
        
        for i = startIndex, #config.spawns do
            local spawn = config.spawns[i]
            if spawn and spawn.coords and spawn.label then
                local coords = spawn.coords
                local x, y, z, w
                
                if type(coords) == 'vector4' or (coords.x and coords.y and coords.z) then
                    x = tonumber(coords.x) or coords.x
                    y = tonumber(coords.y) or coords.y
                    z = tonumber(coords.z) or coords.z
                    w = coords.w and (tonumber(coords.w) or coords.w) or nil
                elseif type(coords) == 'table' and coords[1] and coords[2] and coords[3] then
                    x = tonumber(coords[1]) or coords[1]
                    y = tonumber(coords[2]) or coords[2]
                    z = tonumber(coords[3]) or coords[3]
                    w = coords[4] and (tonumber(coords[4]) or coords[4]) or nil
                else
                    x, y, z, w = getCoordsValues(coords)
                end
                
                if x and y and z then
                    spawns[#spawns+1] = {
                        label = spawn.label,
                        coords = { x = x, y = y, z = z, w = w },
                        icon = spawn.icon or 'map-pin',
                        description = spawn.description or string.format('Start at %s', spawn.label)
                    }
                    print(string.format('[mri_Qspawn] Adicionado spawn do config: %s (%.2f, %.2f, %.2f)', spawn.label, x, y, z))
                else
                    print(string.format('[mri_Qspawn] ERRO: Não foi possível extrair coords do spawn: %s', spawn.label))
                end
            else
                print(string.format('[mri_Qspawn] Spawn %d do config está inválido', i))
            end
        end
    else
        print('[mri_Qspawn] Nenhum spawn configurado no config.client.lua')
    end
    
    -- Adicionar casas do jogador
    local successHouses, houses = pcall(function()
        return lib.callback.await('qbx_spawn:server:getHouses', false)
    end)
    
    if successHouses and houses and #houses > 0 then
        print(string.format('[mri_Qspawn] Carregando %d casas do jogador', #houses))
        for i = 1, #houses do
            if houses[i] and houses[i].coords and houses[i].label then
                spawns[#spawns+1] = {
                    label = houses[i].label,
                    coords = houses[i].coords,
                    propertyId = houses[i].propertyId,
                    icon = 'home',
                    description = string.format('Start at %s', houses[i].label)
                }
                print(string.format('[mri_Qspawn] Adicionada casa: %s', houses[i].label))
            end
        end
    else
        print('[mri_Qspawn] Jogador não possui casas ou erro ao buscar casas')
    end
    
    -- Verificar se temos pelo menos a last_location (já deve ter, mas verificar por segurança)
    if #spawns == 0 then
        print('[mri_Qspawn] AVISO: Nenhum spawn encontrado, adicionando last_location de emergência')
        spawns[#spawns+1] = {
            label = 'last_location',
            coords = { x = -269.4, y = -955.3, z = 31.2, w = 205.8 },
            icon = 'map-pin',
            description = 'Start at last location',
            propertyId = nil
        }
    end
    
    -- Garantir que a last_location está sempre no início da lista
    local lastLocationIndex = nil
    for i = 1, #spawns do
        if spawns[i] and spawns[i].label == 'last_location' then
            lastLocationIndex = i
            break
        end
    end
    
    -- Se encontrou last_location mas não está no início, mover para o início
    if lastLocationIndex and lastLocationIndex > 1 then
        local lastLocationSpawn = spawns[lastLocationIndex]
        table.remove(spawns, lastLocationIndex)
        table.insert(spawns, 1, lastLocationSpawn)
        print('[mri_Qspawn] Last location movida para o início da lista')
    end
    
    print(string.format('[mri_Qspawn] Total de %d spawns configurados (last_location sempre primeiro)', #spawns))
end

-- Exportar função para escolher spawn
exports('chooseSpawn', function(citizenid)
    print(string.format('[mri_Qspawn] chooseSpawn chamado com citizenid: %s', citizenid or 'nil'))
    
    -- Verificar se a UI já está aberta (prevenir abertura duplicada)
    if isNuiOpen then
        print('[mri_Qspawn] AVISO: UI já está aberta, ignorando chooseSpawn')
        return
    end
    
    -- Garantir que NUI focus anterior foi fechado (do multichar ou outras UIs)
    SetNuiFocus(false, false)
    Wait(300) -- Aguardar um pouco mais para garantir que o multichar fechou completamente
    
    -- Limpar estado anterior se houver
    if previewCam and DoesCamExist(previewCam) then
        print('[mri_Qspawn] Limpando câmera anterior antes de configurar novos spawns')
        stopCamera()
        Wait(200)
    end
    
    -- Resetar variáveis de seleção
    selectedSpawn = nil
    selectedSpawnIndex = nil
    previousSelectedSpawn = nil
    previousSelectedSpawnIndex = nil
    
    -- Configurar spawns antes de abrir a UI
    print('[mri_Qspawn] Configurando spawns...')
    setupSpawnsInternal(citizenid)
    
    -- Aguardar um pouco para garantir que os spawns foram configurados
    Wait(400)
    
    -- Verificar se há spawns configurados
    if #spawns == 0 then
        print('[mri_Qspawn] ERRO: Nenhum spawn foi configurado após setupSpawnsInternal!')
        return
    end
    
    print(string.format('[mri_Qspawn] %d spawns configurados, abrindo UI...', #spawns))
    
    -- Agora abrir a UI
    openSpawnUI()
end)

-- Event handler principal (igual ao qbx_spawn)
AddEventHandler('qb-spawn:client:setupSpawns', function(cData, new, apps)
    print('[mri_Qspawn] Evento setupSpawns recebido - new:', new)
    spawns = {}
    
    if new then
        -- Novo personagem - mostrar apenas apartamentos
        print('[mri_Qspawn] Novo personagem - processando apartamentos')
        if apps then
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
                    print(string.format('[mri_Qspawn] Adicionado apartamento: %s', v.label or k))
                end
            end
        end
    else
        -- Personagem existente - mostrar última localização, spawns configurados e casas
        print('[mri_Qspawn] Personagem existente - carregando locais')
        
        local lastLoc, propertyId = lib.callback.await('qbx_spawn:server:getLastLocation')
        if lastLoc then
        spawns[#spawns+1] = {
            label = 'last_location',
                coords = lastLoc,
            icon = 'map-pin',
                description = 'Start at last location',
                propertyId = propertyId
        }
            print('[mri_Qspawn] Adicionada última localização')
        else
            print('[mri_Qspawn] Não foi possível obter última localização')
        end
        
        -- Adicionar spawns do config
        if config.spawns and #config.spawns > 0 then
            print(string.format('[mri_Qspawn] Carregando %d spawns do config', #config.spawns))
        for i = 1, #config.spawns do
            local spawn = config.spawns[i]
                if spawn and spawn.coords and spawn.label then
                    -- Converter coords para formato simples {x, y, z, w}
                    local coords = spawn.coords
                    local x, y, z, w
                    
                    -- Se é vec4/vector4, extrair valores
                    if type(coords) == 'vector4' or (coords.x and coords.y and coords.z) then
                        x = tonumber(coords.x) or coords.x
                        y = tonumber(coords.y) or coords.y
                        z = tonumber(coords.z) or coords.z
                        w = coords.w and (tonumber(coords.w) or coords.w) or nil
                    elseif type(coords) == 'table' and coords[1] and coords[2] and coords[3] then
                        x = tonumber(coords[1]) or coords[1]
                        y = tonumber(coords[2]) or coords[2]
                        z = tonumber(coords[3]) or coords[3]
                        w = coords[4] and (tonumber(coords[4]) or coords[4]) or nil
                    else
                        x, y, z, w = getCoordsValues(coords)
                    end
                    
                    if x and y and z then
            spawns[#spawns+1] = {
                label = spawn.label,
                            coords = { x = x, y = y, z = z, w = w },
                icon = spawn.icon or 'map-pin',
                description = spawn.description or string.format('Start at %s', spawn.label)
            }
                        print(string.format('[mri_Qspawn] Adicionado spawn do config: %s (%.2f, %.2f, %.2f)', spawn.label, x, y, z))
                    else
                        print(string.format('[mri_Qspawn] ERRO: Não foi possível extrair coords do spawn: %s', spawn.label))
                    end
                else
                    print(string.format('[mri_Qspawn] Spawn %d do config está inválido', i))
                end
            end
        else
            print('[mri_Qspawn] Nenhum spawn configurado no config.client.lua ou config.spawns é nil')
            if config then
                print('[mri_Qspawn] Config existe, mas spawns:', config.spawns)
            else
                print('[mri_Qspawn] ERRO: Config é nil!')
            end
        end
        
        -- Adicionar casas do jogador
        local houses = lib.callback.await('qbx_spawn:server:getHouses')
        if houses and #houses > 0 then
            print(string.format('[mri_Qspawn] Carregando %d casas do jogador', #houses))
        for i = 1, #houses do
                if houses[i] and houses[i].coords and houses[i].label then
            spawns[#spawns+1] = {
                label = houses[i].label,
                coords = houses[i].coords,
                propertyId = houses[i].propertyId,
                icon = 'home',
                description = string.format('Start at %s', houses[i].label)
            }
                    print(string.format('[mri_Qspawn] Adicionada casa: %s', houses[i].label))
                end
            end
        else
            print('[mri_Qspawn] Jogador não possui casas')
        end
    end
    
    print(string.format('[mri_Qspawn] Total de %d spawns configurados', #spawns))
    
    Wait(400)
    openSpawnUI()
end)

