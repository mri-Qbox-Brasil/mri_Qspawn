fx_version 'cerulean'
game 'gta5'
version '1.0.0'
lua54 'yes'
author 'wx / woox'
description 'Simple OX based spawn selector'

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/*.lua'
}

shared_scripts {'@ox_lib/init.lua','configs/*.lua'}