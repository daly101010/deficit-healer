-- init.lua
local mq = require('mq')
local Config = require('deficithealer.config')
local HealTracker = require('deficithealer.healtracker')
local TargetMonitor = require('deficithealer.targetmonitor')

local DeficitHealer = {
    running = false,
    charName = mq.TLO.Me.Name(),
}

-- Event pattern for heal landing
-- Format: "You have been healed for X points by SpellName."
-- Format: "TargetName has been healed for X points by SpellName."
mq.event('HealLanded', '#1# ha#*#been healed for #2# point#*#by #3#.', function(target, amount, spell)
    -- Only track our heals
    local numAmount = tonumber(amount)
    if numAmount and spell then
        spell = spell:gsub('%.$', '') -- Remove trailing period
        HealTracker.RecordHeal(spell, numAmount)
    end
end)

function DeficitHealer.Init()
    Config.Load(DeficitHealer.charName)
    HealTracker.Init(nil, Config.learningWeight)
    TargetMonitor.Init()
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
