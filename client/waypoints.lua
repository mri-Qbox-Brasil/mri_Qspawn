-- Markers 3D estilo waypoint sleepless: cria uma DUI por spawn e renderiza
-- como billboard via DrawTexturedPoly. Sem dependência externa.

local M = {}

-- Cache do defaultSpawnIconColor — hydratado lazy do server e atualizado
-- via setColorDefault() quando o admin troca pela UI. Inicia nil: se o
-- main.lua nunca hidratar (config quebrado), colorFor() retorna nil pra
-- spawns sem cor propria — falha loud em vez de mascarar default oculto.
local defaultColor

-- main.lua chama isso depois do ensureConfig() e tambem no broadcast de
-- configChanged.
function M.setColorDefault(color)
    defaultColor = color
end

-- Resolve a cor de um spawn (per-spawn `color` ou o default global).
function M.colorFor(spawn)
    return (spawn and spawn.color) or defaultColor
end

local active = {} -- { coords = vec3, dui, label, color }
local renderThread = nil

-- URL-encode minimal pra label/color que vão no query string da DUI.
local function urlEncode(s)
    return (tostring(s):gsub('[^%w%-_%.~]', function(c)
        return string.format('%%%02X', string.byte(c))
    end))
end

-- Configurações do billboard.
-- IMPORTANTE: nossas coords de spawn estão AO NÍVEL do chão. Por isso GROUND_OFFSET=0
-- (sleepless usa -2 porque assume coords na altura do peito do ped). MIN_HEIGHT alta
-- garante que o marker continua visível mesmo nas câmeras mais próximas (~3-5m).
local DUI_WIDTH      = 512
local DUI_HEIGHT     = 1024
local QUAD_BASE_SIZE = 4.0
local PERSP_DIVISOR  = 20.0
local MIN_SCALE      = 0.3
local ASPECT         = 2.0
local MIN_HEIGHT     = 2.5
local MAX_HEIGHT     = 400.0
local GROUND_OFFSET  = 0.0
local DRAW_DIST      = 1500.0
local FADE_DIST      = 1200.0
local DRAW_DIST_SQ   = DRAW_DIST * DRAW_DIST

local function drawBillboardTriangle(pos, width, height, alpha, dictName, txtName)
    local camPos = GetFinalRenderedCamCoord()
    local halfW = width / 2

    local up      = vec3(0.0, 0.0, 1.0)
    local toCam   = camPos - pos
    local forward = norm(vec3(toCam.x, toCam.y, 0.0))
    local right   = norm(cross(up, forward))

    local topLeft  = pos - (right * halfW) + (up * height)
    local topRight = pos + (right * halfW) + (up * height)
    local bottom   = pos

    DrawTexturedPoly(
        topRight.x, topRight.y, topRight.z,
        topLeft.x,  topLeft.y,  topLeft.z,
        bottom.x,   bottom.y,   bottom.z,
        255, 255, 255, alpha,
        dictName, txtName,
        1.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        0.5, 1.0, 0.0
    )
end

local function startRenderLoop()
    if renderThread then return end
    renderThread = CreateThread(function()
        while #active > 0 do
            local camPos = GetFinalRenderedCamCoord()
            for i = 1, #active do
                local mk = active[i]
                if mk.dui and mk.dui.dictName and mk.dui.txtName then
                    local diff = camPos - mk.coords
                    local distSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z

                    if distSq <= DRAW_DIST_SQ then
                        local dist = math.sqrt(distSq)
                        local perspScale = math.max(MIN_SCALE, dist / PERSP_DIVISOR)
                        local size       = QUAD_BASE_SIZE * perspScale
                        local rawHeight  = size * ASPECT
                        local height     = math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, rawHeight))
                        local width      = size * (height / rawHeight)

                        local alpha = 255
                        if dist > FADE_DIST then
                            local range = DRAW_DIST - FADE_DIST
                            alpha = math.floor(255 * (1 - ((dist - FADE_DIST) / range)))
                        end

                        local basePos = vec3(mk.coords.x, mk.coords.y, mk.coords.z + GROUND_OFFSET)
                        drawBillboardTriangle(basePos, width, height, alpha, mk.dui.dictName, mk.dui.txtName)
                    end
                end
            end
            Wait(0)
        end
        renderThread = nil
    end)
end

-- Cria uma DUI passando label/cor como query params na URL — sem race com várias
-- DUIs subindo em paralelo, e a JS lê os params direto no DOMContentLoaded.
local function createMarkerDui(label, colorHex)
    local url = ('nui://%s/marker/index.html?label=%s&color=%s'):format(
        cache.resource,
        urlEncode(label or ''),
        urlEncode(colorHex or '')
    )
    return lib.dui:new({
        url = url,
        width = DUI_WIDTH,
        height = DUI_HEIGHT,
        debug = false,
    })
end

-- Considera dois spawns como "duplicados" se estiverem a menos de 5m no plano XY.
local DEDUP_RADIUS_SQ = 25.0

-- translateLabel(rawLabel) opcional — usado pra exibir "Última Localização" em
-- vez da key crua 'last_location' no DUI. Dedup ainda usa o label raw como id.
function M.createForSpawns(spawnList, getCoordsFn, translateLabel)
    M.removeAll()
    if not spawnList then return end

    -- Extrai coords válidas primeiro.
    local items = {}
    for i = 1, #spawnList do
        local spawn = spawnList[i]
        if spawn and spawn.coords then
            local x, y, z = getCoordsFn(spawn.coords)
            if x and y and z then
                items[#items + 1] = { x = x, y = y, z = z, spawn = spawn }
            end
        end
    end

    -- Se last_location coincide com algum outro spawn, descarta o last_location
    -- (o spawn nomeado tem prioridade — mostra "Legion Square" em vez de "Last Location").
    for i = #items, 1, -1 do
        if items[i].spawn.label == 'last_location' then
            for j = 1, #items do
                if j ~= i then
                    local dx, dy = items[i].x - items[j].x, items[i].y - items[j].y
                    if dx * dx + dy * dy < DEDUP_RADIUS_SQ then
                        table.remove(items, i)
                        break
                    end
                end
            end
            break
        end
    end

    for i = 1, #items do
        local it = items[i]
        local color = M.colorFor(it.spawn)
        local rawLabel = it.spawn.label or 'SPAWN'
        local label = ((translateLabel and translateLabel(rawLabel)) or rawLabel):upper()
        active[#active + 1] = {
            coords = vec3(it.x, it.y, it.z),
            dui    = createMarkerDui(label, color),
            label  = label,
            color  = color,
        }
    end

    if #active > 0 then startRenderLoop() end
end

function M.removeAll()
    for i = 1, #active do
        if active[i].dui then
            active[i].dui:remove()
        end
    end
    active = {}
end

AddEventHandler('onResourceStop', function(resource)
    if resource == cache.resource then
        M.removeAll()
    end
end)

return M
