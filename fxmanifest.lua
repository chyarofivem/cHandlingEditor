fx_version 'cerulean'
game 'gta5'

name 'cHandlingEditor'
author 'chyaro group'
description 'Standalone in-game vehicle handling editor with live preview and source-file persistence'
version '1.0.0'

ui_page 'html/index.html'

shared_script '@ox_lib/init.lua'
shared_script 'config.lua'

client_script 'client.lua'
server_script 'server.lua'

dependency 'ox_lib'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js'
}
