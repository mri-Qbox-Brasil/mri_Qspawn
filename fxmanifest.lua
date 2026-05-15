fx_version '2.0.1'
game 'gta5'

name 'mri_Qspawn'
description 'Sistema de spawn com NUI moderna baseada em shadcn/ui'
author 'MRI'
version '2.0.1'

ox_lib 'locale'

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

