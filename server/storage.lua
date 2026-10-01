-- Database storage: tables, one-time import of the old JSON files and config helpers (see MANUAL).

local RESOURCE = GetCurrentResourceName()
local IMPORTED_KEY = '__imported'

local ready = promise.new()

---Blocks until the tables exist and the import has run.
function StorageReady()
    Citizen.Await(ready)
end

---Reads a JSON file from the resource; nil if missing or corrupt.
---@param path string
---@return table?
function ReadResourceJson(path)
    local raw = LoadResourceFile(RESOURCE, path)
    if not raw or raw == '' then return nil end
    local ok, parsed = pcall(json.decode, raw)
    if not ok or type(parsed) ~= 'table' then
        print(('[mri_Qspawn] ERRO: %s corrompido, ignorado.'):format(path))
        return nil
    end
    return parsed
end

local function isArray(t)
    return type(t) == 'table' and (next(t) == nil or t[1] ~= nil)
end

local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

---What in `value` differs from `default` (keys unknown to the default are dropped); nil if equal.
---@return any
function ConfigDiff(default, value)
    if default == nil or value == nil then return nil end
    if type(default) ~= type(value) then return nil end
    if type(default) == 'table' and not isArray(default) then
        local out
        for k, v in pairs(value) do
            local d = ConfigDiff(default[k], v)
            if d ~= nil then
                out = out or {}
                out[k] = d
            end
        end
        return out
    end
    if deepEqual(default, value) then return nil end
    return value
end

---Deep-merges `over` into `base` in place; arrays are replaced whole.
function ConfigMerge(base, over)
    for k, v in pairs(over) do
        if type(v) == 'table' and not isArray(v) and type(base[k]) == 'table' and not isArray(base[k]) then
            ConfigMerge(base[k], v)
        else
            base[k] = v
        end
    end
    return base
end

---Upserts the `key` block, or deletes it when `value` is nil.
function SaveSettingRow(key, value)
    if value == nil then
        MySQL.query.await('DELETE FROM `mri_qspawn_settings` WHERE `key` = ?', { key })
    else
        MySQL.query.await(
            'INSERT INTO `mri_qspawn_settings` (`key`, `value`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)',
            { key, json.encode(value) })
    end
end

---Inserts a spawn location at the given sort order.
---@param spawn table { label, coords = { x, y, z, w }, icon?, color?, description? }
---@param order integer
function InsertLocationRow(spawn, order)
    local c = spawn.coords
    return MySQL.insert.await(
        'INSERT INTO `mri_qspawn_locations` (`label`, `x`, `y`, `z`, `heading`, `icon`, `color`, `description`, `sort_order`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { spawn.label, c.x, c.y, c.z, c.w or 0.0, spawn.icon, spawn.color, spawn.description, order })
end

local function createTables()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `mri_qspawn_settings` (
            `key`        VARCHAR(64) NOT NULL,
            `value`      LONGTEXT    NOT NULL,
            `updated_at` TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`key`)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `mri_qspawn_locations` (
            `id`          INT          NOT NULL AUTO_INCREMENT,
            `label`       VARCHAR(100) NOT NULL,
            `x`           DOUBLE       NOT NULL,
            `y`           DOUBLE       NOT NULL,
            `z`           DOUBLE       NOT NULL,
            `heading`     DOUBLE       NOT NULL DEFAULT 0,
            `icon`        VARCHAR(50)  NULL,
            `color`       VARCHAR(9)   NULL,
            `description` TEXT         NULL,
            `sort_order`  INT          NOT NULL DEFAULT 0,
            PRIMARY KEY (`id`)
        )
    ]])
end

local function importOnce()
    local done = MySQL.scalar.await('SELECT 1 FROM `mri_qspawn_settings` WHERE `key` = ?', { IMPORTED_KEY })
    if done then return end

    -- Only what differs from the default becomes a row.
    local defaults = ReadResourceJson('data/config.default.json') or {}
    local old = ReadResourceJson('data/config.json')
    local imported = 0
    if old then
        for key, default in pairs(defaults) do
            local d = ConfigDiff(default, old[key])
            if d ~= nil then
                SaveSettingRow(key, d)
                imported = imported + 1
            end
        end
        print(('[mri_Qspawn] data/config.json importado para o banco (%d blocos alterados).'):format(imported))
    end

    -- Server's old list if present, otherwise the defaults (fresh install).
    local count = MySQL.scalar.await('SELECT COUNT(*) FROM `mri_qspawn_locations`')
    if count == 0 then
        local source = 'data/spawns.json'
        local list = ReadResourceJson(source)
        if not list then
            source = 'data/spawns.default.json'
            list = ReadResourceJson(source) or {}
        end
        local n = 0
        for i = 1, #list do
            local s = list[i]
            if type(s) == 'table' and type(s.label) == 'string' and type(s.coords) == 'table' then
                InsertLocationRow(s, i)
                n = n + 1
            end
        end
        print(('[mri_Qspawn] %d locais de spawn importados de %s.'):format(n, source))
    end

    SaveSettingRow(IMPORTED_KEY, { version = 1 })
end

MySQL.ready(function()
    createTables()
    importOnce()
    ready:resolve(true)
end)
