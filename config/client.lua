return {
    spawns = {
        {
            label = 'Police Department',
            coords = vec4(441.4, -981.9, 30.7, 90.0),
            icon = 'shield',
            description = 'Start at police department'
        },
        {
            label = 'Paleto Bay',
            coords = vec4(80.35, 6424.12, 31.67, 45.5),
            icon = 'leaf',
            description = 'Start at Paleto Bay'
        },
        {
            label = 'Sandy Shores',
            coords = vec4(1961.21, 3740.02, 32.34, 300.0),
            icon = 'leaf',
            description = 'Start at Sandy Shores'
        },
        {
            label = 'Beach',
            coords = vec4(-1370.0, -987.5, 8.4, 90.0),
            icon = 'umbrella',
            description = 'Start at the beach'
        },
        {
            label = 'Motel',
            coords = vec4(327.56, -205.08, 53.08, 163.5),
            icon = 'bed',
            description = 'Start at motel'
        },
    },
    clouds = true, -- Enable the clouds load in with wake up animation
    aerialViewHeight = 700.0, -- Altura máxima da câmera durante transições (temporário)
    previewHeight = 500.0, -- Altura padrão da câmera no estado de visualização (visão satélite, altura mais afastada)
    previewPitch = -90.0, -- Ângulo de inclinação padrão (-90° = visão satélite, olhando diretamente para baixo)
    previewFov = 60.0, -- Campo de visão padrão
    zoomDuration = 3000, -- Duração do zoom até o jogador em ms
    -- Configurações de transição entre spawns (MAXIMAMENTE SUAVES)
    transitionElevationOffset = 60.0, -- Quanto subir na fase de elevação (reduzido para transição mais rápida)
    transitionElevationDuration = 300, -- Duração da elevação em ms (mais rápido)
    transitionPanDurationBase = 7000, -- Duração base do deslocamento horizontal em ms (movimento MUITO suave tipo drone - 7 segundos para transição extremamente lenta e cinematográfica)
    transitionPanSpeed = 0.25, -- Velocidade do deslocamento (metros por ms, extremamente lento para movimento muito suave tipo drone)
    transitionDescentDuration = 400, -- Duração da descida em ms (mais rápido)
    transitionFinalAdjustDuration = 150, -- Duração do ajuste final em ms (mais rápido)
    cameraDriftIntensity = 0.15, -- Intensidade dos micro-movimentos (0.0 = nenhum, 1.0 = máximo)
}

