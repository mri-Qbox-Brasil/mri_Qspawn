-- World placement tools for the spawn panel (mri-world-placement template): a ghost of the player to mark a spawn.

SpawnPlacer = {}

local ROTATE_SPEED = 90.0
local WHEEL_STEP = 15.0
local RAY_DISTANCE = 30.0
-- Weapon wheel, attacks, vehicle weapon scroll and Esc (200), so the keys only drive the tool.
local BLOCKED_CONTROLS = { 14, 15, 16, 17, 24, 25, 37, 44, 140, 141, 142, 200 }
local KEY = { mark = 38, undo = 177, finish = 191, cancel = 200, left = 174, right = 175, wheelUp = 15, wheelDown = 14 }
local START_COLOR = { 0, 230, 153 }
local STOP_COLOR = { 255, 255, 255 }
local ZONE_COLOR = { 255, 210, 0 }
local ZONE_MIN, ZONE_MAX, ZONE_STEP = 0.5, 50.0, 0.5
local SHIFT = 21

local active = false

-- Key rail drawn by the ui_page while a tool runs (false hides it).
-- escBusy tells the MRI pause menu (it reads Esc even while blocked) that Esc belongs to the tool.
local function hud(data)
	SendNUIMessage({ action = 'placeHud', data = data })
	if (data ~= false) ~= (LocalPlayer.state.escBusy == true) then LocalPlayer.state:set('escBusy', data ~= false, false) end
end

local function block()
	for i = 1, #BLOCKED_CONTROLS do DisableControlAction(0, BLOCKED_CONTROLS[i], true) end
	DisableControlAction(0, KEY.finish, true)
end

-- The ox_lib raycast waits a frame, so it runs apart and the draw loop keeps every frame.
local function trackAim()
	local aim = {}
	CreateThread(function()
		while active do
			local hit, _, coords = lib.raycast.fromCamera(1 | 16, 4, RAY_DISTANCE)
			aim.coords = hit and coords or nil
		end
	end)
	return aim
end

local function ghostPed(model, heading)
	local hash = tonumber(model) or joaat(model)
	if not IsModelInCdimage(hash) or not pcall(lib.requestModel, hash, 10000) then return nil end
	local coords = GetEntityCoords(cache.ped)
	local ped = CreatePed(4, hash, coords.x, coords.y, coords.z, heading, false, false)
	SetModelAsNoLongerNeeded(hash)
	SetPedDefaultComponentVariation(ped)
	SetEntityAlpha(ped, 170, false)
	SetEntityCollision(ped, false, false)
	FreezeEntityPosition(ped, true)
	SetEntityInvincible(ped, true)
	SetBlockingOfNonTemporaryEvents(ped, true)
	return ped
end

-- Suite accent from the mri:color convar, like the mri_Qbox zone drawer.
local function accent()
	local hex = GetConvar('mri:color', '#00E699'):match('^#(%x%x%x%x%x%x)') or '00E699'
	return { tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16) }
end

-- Aim cursor of a point without a model; a sphere marker scales by radius, so 0.1 is 20 cm across.
local function drawCursor(point, color)
	DrawMarker(28, point.x, point.y, point.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.1, 0.1, 0.1, color[1], color[2], color[3], 220, false, false, 2, false, nil, nil, false)
end

local function drawStop(point, color)
	DrawMarker(1, point.x, point.y, point.z - 0.02, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.6, 0.6, 0.35, color[1], color[2], color[3], 170, false, false, 2, false, nil, nil, false)
end

-- Box centered on `c`, turned by `heading`, `size` = { x, y, z } full lengths.
local function drawBox(c, size, heading, color, alpha)
	local rad = math.rad(heading)
	local cos, sin = math.cos(rad), math.sin(rad)
	local hx, hy, hz = size.x / 2, size.y / 2, size.z / 2
	local corners = {}
	for i, offset in ipairs({ { -hx, -hy }, { hx, -hy }, { hx, hy }, { -hx, hy } }) do
		local rx, ry = offset[1] * cos - offset[2] * sin, offset[1] * sin + offset[2] * cos
		corners[i] = { c.x + rx, c.y + ry }
	end
	local r, g, b, a = color[1], color[2], color[3], alpha or 255
	for i = 1, 4 do
		local p, n = corners[i], corners[i % 4 + 1]
		DrawLine(p[1], p[2], c.z - hz, n[1], n[2], c.z - hz, r, g, b, a)
		DrawLine(p[1], p[2], c.z + hz, n[1], n[2], c.z + hz, r, g, b, a)
		DrawLine(p[1], p[2], c.z - hz, p[1], p[2], c.z + hz, r, g, b, a)
	end
end

-- Arrow on the floor of the box pointing where `heading` faces.
local function drawArrow(c, heading, color)
	local rad = math.rad(heading)
	local length, tip = 2.0, 0.3
	local ex, ey = c.x - math.sin(rad) * length, c.y + math.cos(rad) * length
	local z = c.z + 0.5
	DrawLine(c.x, c.y, z, ex, ey, z, color[1], color[2], color[3], 255)
	for _, side in ipairs({ 150, -150 }) do
		local a = rad + math.rad(side)
		DrawLine(ex, ey, z, ex - math.sin(a) * tip, ey + math.cos(a) * tip, z, color[1], color[2], color[3], 255)
	end
end

local function drawLabel(c, text)
	local onScreen, x, y = World3dToScreen2d(c.x, c.y, c.z)
	if not onScreen then return end
	SetTextScale(0.35, 0.35)
	SetTextFont(4)
	SetTextColour(255, 255, 255, 215)
	SetTextOutline()
	SetTextCentre(true)
	BeginTextCommandDisplayText('STRING')
	AddTextComponentSubstringPlayerName(text)
	EndTextCommandDisplayText(x, y)
end

-- The pause menu opens when Esc is released, so it stays blocked until the key is up.
local function releaseEsc()
	repeat
		DisableControlAction(0, KEY.cancel, true)
		Wait(0)
	until not IsDisabledControlPressed(0, KEY.cancel)
	DisableControlAction(0, KEY.cancel, true)
end

local function clampSize(value)
	return math.min(ZONE_MAX, math.max(ZONE_MIN, value))
end

function SpawnPlacer.isActive()
	return active
end

function SpawnPlacer.cancel()
	active = false
end

---Ghost follows the aim; arrows and wheel rotate, E confirms, Backspace or Esc cancels.
---Without `model` (an interaction point) a sphere in the suite accent follows the aim instead and there is no heading.
---@param opts { model?: string|number, heading?: number }
---@return { coords: { x: number, y: number, z: number }, heading?: number }|nil
function SpawnPlacer.point(opts)
	if active then return nil end
	local heading = tonumber(opts.heading) or GetEntityHeading(cache.ped)
	local ghost
	if opts.model then
		ghost = ghostPed(opts.model, heading)
		if not ghost then return nil end
	end

	active = true
	hud({ mode = ghost and 'place' or 'spot' })
	local aim = trackAim()
	local color = accent()

	local result, last
	while active do
		local frame = GetFrameTime()
		block()

		local coords = aim.coords
		if coords and coords ~= last then
			last = coords
			if ghost then SetEntityCoords(ghost, coords.x, coords.y, coords.z, false, false, false, false) end
		end

		if ghost then
			if IsControlPressed(0, KEY.left) then heading = heading + ROTATE_SPEED * frame end
			if IsControlPressed(0, KEY.right) then heading = heading - ROTATE_SPEED * frame end
			if IsDisabledControlJustPressed(0, KEY.wheelUp) then heading = heading + WHEEL_STEP end
			if IsDisabledControlJustPressed(0, KEY.wheelDown) then heading = heading - WHEEL_STEP end
			heading = heading % 360
			SetEntityHeading(ghost, heading)
		elseif last then
			drawCursor(last, color)
		end

		if IsControlJustPressed(0, KEY.mark) and last then
			PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
			result = { coords = { x = last.x, y = last.y, z = last.z } }
			if ghost then result.heading = math.floor(heading * 100 + 0.5) / 100 end
			break
		elseif IsDisabledControlJustPressed(0, KEY.cancel) or IsControlJustPressed(0, KEY.undo) then
			PlaySoundFrontend(-1, 'BACK', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
			releaseEsc()
			break
		end
		Wait(0)
	end

	active = false
	hud(false)
	if ghost then DeleteEntity(ghost) end
	return result
end

---Box with heading around the player: walk to place it, the player's heading turns it, wheel sizes it,
---Shift + wheel sets the height, E marks. With `multiple`, Backspace undoes and Enter finishes; otherwise
---E returns at once and Backspace cancels. Esc always cancels. `refs` are zones already placed, drawn green.
---@param opts { size?: { x: number, y: number, z: number }, multiple?: boolean, refs?: { coords: table, size: table, heading: number, label?: string }[] }
---@return { coords: table, heading: number, size: table }|{ coords: table, heading: number, size: table }[]|nil
function SpawnPlacer.zone(opts)
	if active then return nil end
	local s = type(opts.size) == 'table' and opts.size or { x = 3.0, y = 3.0, z = 3.0 }
	local size = { x = clampSize(tonumber(s.x) or 3.0), y = clampSize(tonumber(s.y) or 3.0), z = clampSize(tonumber(s.z) or 3.0) }
	local refs = type(opts.refs) == 'table' and opts.refs or {}
	local marks = {}

	active = true
	local function push() hud({ mode = 'zone', size = size, count = #marks, multiple = opts.multiple == true }) end
	push()

	local result
	while active do
		block()

		for _, ref in ipairs(refs) do
			drawBox(ref.coords, ref.size, ref.heading or 0.0, START_COLOR, 200)
			if ref.label then drawLabel(vec3(ref.coords.x, ref.coords.y, ref.coords.z + ref.size.z / 2 + 0.2), ref.label) end
		end
		for _, mark in ipairs(marks) do drawBox(mark.coords, mark.size, mark.heading, START_COLOR, 200) end

		local coords, heading = GetEntityCoords(cache.ped), GetEntityHeading(cache.ped)
		drawBox(coords, size, heading, ZONE_COLOR)
		drawArrow(coords, heading, ZONE_COLOR)
		drawLabel(vec3(coords.x, coords.y, coords.z + size.z / 2 + 0.3), ('%.1f x %.1f x %.1f m'):format(size.x, size.y, size.z))

		local step = (IsDisabledControlJustPressed(0, KEY.wheelUp) and 1 or 0) - (IsDisabledControlJustPressed(0, KEY.wheelDown) and 1 or 0)
		if step ~= 0 then
			if IsControlPressed(0, SHIFT) then
				size.z = clampSize(size.z + step * ZONE_STEP)
			else
				size.x, size.y = clampSize(size.x + step * ZONE_STEP), clampSize(size.y + step * ZONE_STEP)
			end
			push()
		end

		if IsControlJustPressed(0, KEY.mark) then
			local mark = {
				coords = { x = coords.x, y = coords.y, z = coords.z },
				heading = math.floor(heading * 100 + 0.5) / 100,
				size = { x = size.x, y = size.y, z = size.z },
			}
			PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
			if not opts.multiple then
				result = mark
				break
			end
			marks[#marks + 1] = mark
			push()
		elseif IsControlJustPressed(0, KEY.undo) then
			PlaySoundFrontend(-1, 'BACK', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
			if not opts.multiple then break end
			if #marks > 0 then
				marks[#marks] = nil
				push()
			end
		elseif opts.multiple and IsDisabledControlJustPressed(0, KEY.finish) then
			result = #marks > 0 and marks or nil
			break
		elseif IsDisabledControlJustPressed(0, KEY.cancel) then
			PlaySoundFrontend(-1, 'BACK', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
			releaseEsc()
			break
		end
		Wait(0)
	end

	active = false
	hud(false)
	return result
end

---Marks a path from `start`: E adds where the player aims, Backspace undoes, Enter finishes, Esc cancels.
---Finishing with no stops counts as cancel, so the caller keeps the path it had.
---@param opts { start: vector3|table, max?: integer }
---@return { x: number, y: number, z: number }[]|nil
function SpawnPlacer.path(opts)
	if active then return nil end
	local s = opts.start
	if type(s) ~= 'table' and type(s) ~= 'vector3' then return nil end
	local start = vec3(s.x + 0.0, s.y + 0.0, s.z + 0.0)
	local max = opts.max or 20

	local points = {}
	active = true
	hud({ mode = 'route', count = 0 })
	local aim = trackAim()

	local result
	while active do
		block()
		local last = aim.coords

		local previous = start
		drawStop(start, START_COLOR)
		for _, point in ipairs(points) do
			local here = vec3(point.x, point.y, point.z)
			DrawLine(previous.x, previous.y, previous.z + 0.1, here.x, here.y, here.z + 0.1, START_COLOR[1], START_COLOR[2], START_COLOR[3], 220)
			drawStop(here, STOP_COLOR)
			previous = here
		end
		if last then
			DrawLine(previous.x, previous.y, previous.z + 0.1, last.x, last.y, last.z + 0.1, 255, 255, 255, 110)
			drawStop(last, STOP_COLOR)
		end

		if IsControlJustPressed(0, KEY.mark) and last and #points < max then
			points[#points + 1] = { x = last.x, y = last.y, z = last.z }
			PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
			hud({ mode = 'route', count = #points })
		elseif IsControlJustPressed(0, KEY.undo) and #points > 0 then
			points[#points] = nil
			PlaySoundFrontend(-1, 'BACK', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
			hud({ mode = 'route', count = #points })
		elseif IsDisabledControlJustPressed(0, KEY.finish) then
			result = #points > 0 and points or nil
			break
		elseif IsDisabledControlJustPressed(0, KEY.cancel) then
			PlaySoundFrontend(-1, 'BACK', 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
			releaseEsc()
			break
		end
		Wait(0)
	end

	active = false
	hud(false)
	return result
end

-- A restart mid-tool would leave the MRI pause menu locked.
AddEventHandler('onResourceStop', function(resource)
	if resource == cache.resource and LocalPlayer.state.escBusy then LocalPlayer.state:set('escBusy', false, false) end
end)
