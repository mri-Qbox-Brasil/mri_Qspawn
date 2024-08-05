fx_version 'cerulean'
game 'gta5'
version '1.0.0'
lua54 'yes'
author 'wx / woox'
description 'Simple OX based spawn selector'

shared_scripts {
    '@ox_lib/init.lua',
    'configs/*.lua'
}

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/*.lua'
}

server_scripts {
    'server/*.lua'
}