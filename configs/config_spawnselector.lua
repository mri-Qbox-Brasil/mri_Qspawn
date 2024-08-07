cfg = {}
cfg.Debug = true -- Ativa o comando /escolha que aciona a exportação de seletor de spawn
cfg.Timeout = 1000

cfg.AlwaysChooseSpawn = false -- Deixe o jogador sempre escolher onde aparecer
cfg.ConfirmSpawn = true -- Deixe o jogador confirmar a localização da Spawn
cfg.DefaultLocation = vector4(-1041.54, -2744.57, 21.35, 327.48) -- Se não há para onde ir ...
cfg.Locations = {
    ["Departamento de Polícia"] = {
        Spawn = vector4(428.8641, -981.2666, 30.7103, 95.1865),
        Icon = 'building-shield',
        Description = "Edifício principal do departamento de polícia local"
    },
    ["Airport"] = {
        Spawn = vector4(-1041.5402, -2744.5745, 21.3594, 327.4831),
        Icon = 'plane-arrival',
        Description = "Aeroporto Internacional de Los Santos"
    },
    ["Hospital"] = {
        Spawn = vector4(373.5801, -597.6584, 28.8329, 238.7010),
        Icon = 'hospital',
        Description = "Tenho a impressão que já estive aqui!?"
    },
    ["Paleto Bay"] = {
        Spawn = vector4(145.5080, 6641.6006, 31.5540, 179.7455),
        Icon = 'mountain-city',
        Description = "Paleto Bay é uma pequena cidade localizada no condado de Blaine, em San Andreas"
    },
}
cfg.MenuTitle = 'Escolha um local'
cfg.LastLocation = {
    Title = "Última localização",
    Icon = 'map-location-dot',
    Description = "Local onde você estava"
}