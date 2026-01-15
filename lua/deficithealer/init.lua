-- init.lua
local mq = require('mq')
local Config = require('deficithealer.config')

local DeficitHealer = {
    running = false,
    charName = mq.TLO.Me.Name(),
}

function DeficitHealer.Init()
    Config.Load(DeficitHealer.charName)
    print('[DeficitHealer] Loaded configuration for ' .. DeficitHealer.charName)
    DeficitHealer.running = true
end

function DeficitHealer.Shutdown()
    Config.Save(DeficitHealer.charName)
    DeficitHealer.running = false
    print('[DeficitHealer] Shutdown complete')
end

-- Binds
mq.bind('/deficithealer', function()
    if DeficitHealer.running then
        DeficitHealer.Shutdown()
    else
        DeficitHealer.Init()
    end
end)

mq.bind('/dh', function()
    if DeficitHealer.running then
        DeficitHealer.Shutdown()
    else
        DeficitHealer.Init()
    end
end)

-- Main loop placeholder
DeficitHealer.Init()

while DeficitHealer.running do
    mq.delay(100)
    mq.doevents()
end

DeficitHealer.Shutdown()
