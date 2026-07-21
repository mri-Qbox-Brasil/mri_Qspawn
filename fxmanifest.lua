fx_version 'cerulean'
game 'gta5'

name 'mri_Qspawn'
description 'Sistema de spawn com NUI moderna baseada em shadcn/ui'
author 'MRI'
version '2.4.0'

ox_lib 'locale'

-- Substitui o qbx_spawn (registra os mesmos callbacks). NÃO rodar os dois juntos.
provide 'qbx_spawn'

-- Dependência dura: usa exports.qbx_core e o entrypoint chooseSpawn é chamado
-- pelo multichar do qbx_core. Declara pra falhar cedo e fixar ordem de carga.
dependency 'qbx_core'

shared_scripts {
	'@ox_lib/init.lua',
}

client_scripts {
	'client/main.lua',
}

server_scripts {
	'@oxmysql/lib/MySQL.lua',
	'server/config.lua', -- expoe GetSpawnConfig() global, usado por main.lua
	'server/spawns.lua',
	'server/main.lua',
}

ui_page 'html/index.html'

files {
	'html/**/*',
	'client/waypoints.lua',
	'locales/*.json',
	'data/*.json',
}

lua54 'yes'
use_experimental_fxv2_oal 'yes'

