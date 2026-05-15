-- Le e persiste settings de UX em data/config.json. O proprio JSON e a
-- fonte de verdade do shape e dos defaults — adicionar setting novo so
-- precisa de edit no JSON + input correspondente no ConfigPanel.tsx.
--
-- Sem fallback de codigo: se o JSON for deletado/corrompido, o getter
-- retorna table vazia e os callers Lua usam `or <fallback inline>` pra
-- comportamentos minimos. Editavel via aba "Configurações" do /adminspawn
-- (gateado por mri_Qspawn.admin OU `command` ACE) + broadcast pra clients
-- reaplicarem sem restart.

local CONFIG_FILE = 'data/config.json'

local config = {}

local function loadFromDisk()
    local raw = LoadResourceFile(GetCurrentResourceName(), CONFIG_FILE)
    if not raw or raw == '' then
        print(('[mri_Qspawn] AVISO: %s ausente — usando config vazio.'):format(CONFIG_FILE))
        config = {}
        return
    end
    local ok, parsed = pcall(json.decode, raw)
    if not ok or type(parsed) ~= 'table' then
        print(('[mri_Qspawn] AVISO: %s corrompido — usando config vazio.'):format(CONFIG_FILE))
        config = {}
        return
    end
    config = parsed
end

local function saveToDisk()
    local ok = SaveResourceFile(GetCurrentResourceName(), CONFIG_FILE, json.encode(config, { indent = true }), -1)
    if not ok then
        print('[mri_Qspawn] ERRO: falha ao escrever ' .. CONFIG_FILE)
    end
    return ok
end

local function isAdmin(source)
    return IsPlayerAceAllowed(source, 'mri_Qspawn.admin')
        or IsPlayerAceAllowed(source, 'command')
end

loadFromDisk()

-- Lua-side getter pra outros scripts/comandos lerem (ex: o broadcast usa
-- pra mandar a versao corrente em runtime sem reler do disco).
function GetSpawnConfig()
    return config
end

lib.callback.register('mri_Qspawn:server:getConfig', function()
    return config
end)

lib.callback.register('mri_Qspawn:server:saveConfig', function(source, payload)
    if not isAdmin(source) then return false, 'sem permissão' end
    if type(payload) ~= 'table' then return false, 'payload inválido' end

    config = payload
    if not saveToDisk() then return false, 'falha ao salvar' end

    -- Broadcast pra todos os clients reaplicarem sem restart.
    TriggerClientEvent('mri_Qspawn:client:configChanged', -1, config)
    return true, config
end)
