-- Arrival effect: sonar pulse from the character's feet on spawn (see MANUAL "Chegada").

local M = {}

-- Outline only on objects: SetEntityDrawOutline on peds/vehicles crashes the game.
local OUTLINE_POOLS = { 'CObject' }
local CONTACT_POOLS = { 'CPed', 'CVehicle' }

local RING_MARKER = 25    -- HorizontalCircleSkinny
local WALL_MARKER = 1     -- VerticalCylinder
local CONTACT_MARKER = 0  -- UpsideDownCone

local RADIUS = 60.0
local WAVE_MS = 3000
local CHARGE_MS = 450
local MATERIALIZE_MS = 1500
local FLASH_MS = 350

local PINGS = 3
local PING_INTERVAL = 300
local PING_FALLOFF = 0.6

local ECHOES = { { at = 0.88, alpha = 0.45 }, { at = 0.74, alpha = 0.2 } }
local WALL_HEIGHT = 2.0
local WALL_ALPHA = 110
local FRONT_LIGHTS = 6
local FRONT_LIGHT_RANGE = 10.0
local LIGHT_INTENSITY = 8.0

local MAX_CONTACTS = 40
local CONTACT_HOLD = 2200
local CONTACT_PULSES = 3
local CONTACT_PULSE_MS = 280
local CONTACT_PULSE_GAP = 140

-- Shader 1 is the only one that honors alpha (shader 0 uses SetColorNoAlpha in FiveM).
local OUTLINE_SHADER = 1
local MAX_OUTLINED = 120
local OUTLINE_BUMP = 0.55
local OUTLINE_ATTACK = 120
local OUTLINE_DECAY = 900
local OUTLINE_OFF = 0.02

local POSTFX_IN = 'FocusIn'
local POSTFX_OUT = 'FocusOut'
local SOUND_NAME = 'Beat_Pulse_Default'
local SOUND_SET = 'GTAO_Dancing_Sounds'

local lit = {}
local generation = 0 -- a new pulse cancels the previous one
local postfxOn = false

local function hexToRgb(hex)
    local r, g, b = hex:match('^#(%x%x)(%x%x)(%x%x)')
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function easeOutQuart(t)
    return 1 - (1 - t) ^ 4
end

local function setOutline(ent, on)
    if not DoesEntityExist(ent) then
        lit[ent] = nil
        return
    end
    SetEntityDrawOutline(ent, on)
    lit[ent] = on or nil
end

local function clearOutlines()
    for ent in pairs(lit) do
        if DoesEntityExist(ent) then SetEntityDrawOutline(ent, false) end
    end
    lit = {}
end

-- FocusIn stays on until stopped; FocusOut fades the screen back.
local function stopPostfx(fadeOut)
    if not postfxOn then return end
    AnimpostfxStop(POSTFX_IN)
    postfxOn = false
    if fadeOut then AnimpostfxPlay(POSTFX_OUT, 0, false) end
end

local function collect(pools, origin, max)
    local list = {}
    for p = 1, #pools do
        local pool = GetGamePool(pools[p])
        for i = 1, #pool do
            local ent = pool[i]
            if ent ~= cache.ped then
                local dist = #(GetEntityCoords(ent) - origin)
                if dist <= RADIUS then
                    list[#list + 1] = { ent = ent, dist = dist }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    for i = #list, max + 1, -1 do list[i] = nil end
    return list
end

local function contactShape(ent)
    if IsEntityAVehicle(ent) then
        local min, max = GetModelDimensions(GetEntityModel(ent))
        local size = math.max(max.x - min.x, max.y - min.y)
        return math.min(size * 0.45, 2.0), max.z + 0.5
    end
    return 0.8, 1.15
end

local function drawContact(c, now, r, g, b)
    local k = (now - c.hitAt) / CONTACT_HOLD
    if k >= 1.0 or not DoesEntityExist(c.ent) then
        c.done = true
        return
    end
    local pos = GetEntityCoords(c.ent)
    local ground = pos.z - GetEntityHeightAboveGround(c.ent)

    local elapsed = now - c.hitAt
    for p = 0, CONTACT_PULSES - 1 do
        local pk = (elapsed - p * CONTACT_PULSE_GAP) / CONTACT_PULSE_MS
        if pk >= 0.0 and pk < 1.0 then
            local ring = c.size * (0.15 + 0.85 * easeOutQuart(pk))
            DrawMarker(RING_MARKER, pos.x, pos.y, ground + 0.03,
                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                ring, ring, 1.0,
                r, g, b, math.floor(255 * (1.0 - pk)),
                false, false, 2, false, nil, nil, false)
        end
    end

    DrawMarker(CONTACT_MARKER, pos.x, pos.y, ground + c.top,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.16, 0.16, 0.16,
        r, g, b, math.floor(220 * (1.0 - k)),
        false, false, 2, true, nil, nil, false)
end

local function drawRing(origin, radius, r, g, b, alpha)
    if radius <= 0.05 or alpha <= 0 then return end
    DrawMarker(RING_MARKER, origin.x, origin.y, origin.z + 0.05,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        radius * 2.0, radius * 2.0, 1.0,
        r, g, b, alpha,
        false, false, 2, false, nil, nil, false)
end

-- Wind-up before the burst; false if a newer pulse took over.
local function charge(origin, r, g, b, gen)
    local start = GetGameTimer()
    while generation == gen do
        local k = (GetGameTimer() - start) / CHARGE_MS
        if k >= 1.0 then return true end
        local closing = 1.0 - k * k
        drawRing(origin, 0.15 + 2.6 * closing, r, g, b, math.floor(200 * k))
        drawRing(origin, 0.1 + 1.5 * closing, r, g, b, math.floor(110 * k))
        DrawLightWithRange(origin.x, origin.y, origin.z + 1.0, r, g, b, 4.0, LIGHT_INTENSITY * k)
        Wait(0)
    end
    return false
end

-- Only the lead wave has sound and flash; followers are weaker by `strength`.
local function wave(origin, r, g, b, gen, playSound, isLead, strength)
    local contacts = collect(CONTACT_POOLS, origin, MAX_CONTACTS)
    for i = 1, #contacts do
        contacts[i].size, contacts[i].top = contactShape(contacts[i].ent)
    end

    if isLead and playSound then
        PlaySoundFrontend(-1, SOUND_NAME, SOUND_SET, true)
    end

    local start = GetGameTimer()
    local nextContact = 1

    while generation == gen do
        local now = GetGameTimer()
        local t = math.min((now - start) / WAVE_MS, 1.0)
        local front = RADIUS * easeOutQuart(t)
        -- Stays strong until the last stretch so the ring reaches the radius visible.
        local fade = (1.0 - t ^ 3) * strength

        while nextContact <= #contacts and contacts[nextContact].dist <= front do
            contacts[nextContact].hitAt = now
            nextContact = nextContact + 1
        end
        local pending = false
        for i = 1, nextContact - 1 do
            local c = contacts[i]
            if not c.done then
                drawContact(c, now, r, g, b)
                pending = pending or not c.done
            end
        end

        local sinceStart = now - start
        if isLead and sinceStart < FLASH_MS then
            local k = 1.0 - sinceStart / FLASH_MS
            DrawLightWithRange(origin.x, origin.y, origin.z + 1.5, r, g, b, RADIUS * 0.5, LIGHT_INTENSITY * 2.0 * k)
        end

        if t < 1.0 then
            drawRing(origin, front, r, g, b, math.floor(230 * fade))
            if isLead then
                drawRing(origin, math.max(front - 0.35, 0.0), r, g, b, math.floor(200 * fade))
            end
            for i = 1, #ECHOES do
                local e = ECHOES[i]
                drawRing(origin, front * e.at, r, g, b, math.floor(230 * e.alpha * fade))
            end

            DrawMarker(WALL_MARKER, origin.x, origin.y, origin.z - 0.2,
                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                front * 2.0, front * 2.0, WALL_HEIGHT,
                r, g, b, math.floor(WALL_ALPHA * fade),
                false, false, 2, false, nil, nil, false)

            local intensity = LIGHT_INTENSITY * fade
            for i = 1, FRONT_LIGHTS do
                local ang = (i / FRONT_LIGHTS) * math.pi * 2.0
                DrawLightWithRange(origin.x + math.cos(ang) * front, origin.y + math.sin(ang) * front,
                    origin.z + 1.0, r, g, b, FRONT_LIGHT_RANGE, intensity)
            end
        end

        if t >= 1.0 and not pending then break end
        Wait(0)
    end
end

-- Outline color is global, so the brightness envelope is shared by every object.
local function outlineSweep(origin, r, g, b, gen)
    local objs = collect(OUTLINE_POOLS, origin, MAX_OUTLINED)
    if #objs == 0 then return end
    local start = GetGameTimer()
    local lastWave = (PINGS - 1) * PING_INTERVAL
    local nextObj = 1

    while generation == gen do
        local elapsed = GetGameTimer() - start

        local level = 0.0
        for i = 1, PINGS do
            local x = elapsed - (i - 1) * PING_INTERVAL
            if x > 0 then
                local env = x < OUTLINE_ATTACK and x / OUTLINE_ATTACK
                    or math.exp(-(x - OUTLINE_ATTACK) / OUTLINE_DECAY)
                level = level + OUTLINE_BUMP * PING_FALLOFF ^ (i - 1) * env
            end
        end
        level = math.min(level, 1.0)
        SetEntityDrawOutlineColor(r, g, b, math.floor(255 * level))

        local front = RADIUS * easeOutQuart(math.min(elapsed / WAVE_MS, 1.0))
        while nextObj <= #objs and objs[nextObj].dist <= front do
            setOutline(objs[nextObj].ent, true)
            nextObj = nextObj + 1
        end

        if elapsed > lastWave + OUTLINE_ATTACK and level < OUTLINE_OFF then break end
        Wait(0)
    end

    -- A newer pulse already cleared everything.
    if generation ~= gen then return end
    clearOutlines()
end

---Fades the ped in instead of popping it.
---@param ped number
function M.materialize(ped)
    SetEntityAlpha(ped, 0, false)
    SetEntityVisible(ped, true, false)
    CreateThread(function()
        local start = GetGameTimer()
        while true do
            local t = math.min((GetGameTimer() - start) / MATERIALIZE_MS, 1.0)
            SetEntityAlpha(ped, math.floor(255 * t), false)
            if t >= 1.0 then break end
            Wait(0)
        end
        ResetEntityAlpha(ped)
    end)
end

---Fires the sonar from `origin` (the ped's feet).
---@param origin vector3
---@param accentHex string #RRGGBB (mri:color)
---@param playSound boolean
function M.pulse(origin, accentHex, playSound)
    generation = generation + 1
    local gen = generation
    clearOutlines()

    local r, g, b = hexToRgb(accentHex)
    SetEntityDrawOutlineShader(OUTLINE_SHADER)
    SetEntityDrawOutlineColor(r, g, b, 255)
    stopPostfx(false)

    CreateThread(function()
        if not charge(origin, r, g, b, gen) then return end

        AnimpostfxPlay(POSTFX_IN, 0, false)
        postfxOn = true
        CreateThread(function()
            Wait(WAVE_MS)
            if generation == gen then stopPostfx(true) end
        end)

        CreateThread(function() outlineSweep(origin, r, g, b, gen) end)
        for i = 1, PINGS do
            if generation ~= gen then return end
            local strength = PING_FALLOFF ^ (i - 1)
            CreateThread(function() wave(origin, r, g, b, gen, playSound, i == 1, strength) end)
            if i < PINGS then Wait(PING_INTERVAL) end
        end
    end)
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= cache.resource then return end
    clearOutlines()
    stopPostfx(false)
end)

return M
