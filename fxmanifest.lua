fx_version 'cerulean'
game 'gta5'
version '1.0.0'
lua54 'yes'
author 'wx / woox'
description 'Simple OX based spawn selector'

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/playerdata.lua',
    'configs/*.lua'
}

client_scripts {
    'client/*.lua'
}

server_scripts {
    'server/*.lua'
}