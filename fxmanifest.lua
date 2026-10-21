fx_version 'cerulean'
game 'gta5'

name 'mri_Qspawn'
description 'Sistema de spawn com NUI moderna baseada em shadcn/ui'
author 'MRI'
version '2.8.0'

ox_lib 'locale'

-- Replaces qbx_spawn (same callbacks); never run both.
provide 'qbx_spawn'

-- The qbx_core multichar calls chooseSpawn; declared to fail early and fix the load order.
dependency 'qbx_core'

shared_scripts {
	'@ox_lib/init.lua',
}

client_scripts {
	'client/placement.lua',
	'client/main.lua',
}

server_scripts {
	'@oxmysql/lib/MySQL.lua',
	'server/storage.lua', -- tables, one-time import and config helpers
	'server/config.lua', -- global GetSpawnConfig(), used by main.lua
	'server/spawns.lua',
	'server/main.lua',
}

ui_page 'html/index.html'

files {
	'html/**/*',
	'locales/*.json',
	'data/*.json',
	'client/arrival.lua',
}

lua54 'yes'
use_experimental_fxv2_oal 'yes'

