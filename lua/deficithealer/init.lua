-- init.lua
-- Main entry point for Deficit-Based Healer
-- Integrates all modules and runs the healing loop

local mq = require('mq')
require 'ImGui'

local Config = require('deficithealer.config')
local HealTracker = require('deficithealer.healtracker')
local TargetMonitor = require('deficithealer.targetmonitor')
local HealSelector = require('deficithealer.healselector')
local Proactive = require('deficithealer.proactive')
local Analytics = require('deficithealer.analytics')
local UI = require('deficithealer.ui')
local Persistence = require('deficithealer.persistence')

local DeficitHealer = {
    running = false,
    charName = mq.TLO.Me.Name(),
    casting = false,
}

-- Event pattern for heal landing
-- Format: "You have been healed for X points by SpellName."
-- Format: "TargetName has been healed for X points by SpellName."
mq.event('HealLanded', '#1# ha#*#been healed for #2# point#*#by #3#.', function(target, amount, spell)
    local numAmount = tonumber(amount)
    if numAmount and spell then
        spell = spell:gsub('%.$', '')  -- Remove trailing period
        HealTracker.RecordHeal(spell, numAmount)
    end
end)

function DeficitHealer.Init()
    DeficitHealer.charName = mq.TLO.Me.Name()

    -- Load saved data
    local healData, analyticsHistory = Persistence.Load(DeficitHealer.charName)

    -- Initialize all modules
    Config.Load(DeficitHealer.charName)
    HealTracker.Init(healData, Config.learningWeight)
    TargetMonitor.Init()
    HealSelector.Init(Config, HealTracker)
    Proactive.Init(Config, HealTracker, TargetMonitor)
    Analytics.Init()
    UI.Init(Config, HealTracker, TargetMonitor, HealSelector, Analytics)

    DeficitHealer.running = true
    print('[DeficitHealer] Initialized for ' .. DeficitHealer.charName)
end

function DeficitHealer.Shutdown()
    -- Save all data
    Persistence.Save(DeficitHealer.charName, HealTracker.GetData(), Analytics.GetHistory())
    Analytics.SaveSession()
    Config.Save(DeficitHealer.charName)

    DeficitHealer.running = false
    print('[DeficitHealer] Shutdown complete - data saved')
end

function DeficitHealer.CastHeal(spellName, targetName)
    if DeficitHealer.casting then return false end

    mq.cmdf('/target %s', targetName)
    mq.delay(100)
    mq.cmdf('/cast "%s"', spellName)

    DeficitHealer.casting = true
    HealSelector.SetLastAction(string.format('Casting %s on %s', spellName, targetName))

    return true
end

function DeficitHealer.ProcessHealing()
    -- Update target info
    TargetMonitor.Update()
    Proactive.Update()

    -- Check casting state
    if mq.TLO.Me.Casting() then
        DeficitHealer.casting = true
        return
    else
        DeficitHealer.casting = false
    end

    local allTargets = TargetMonitor.GetAllTargets()
    local priorityTargets = TargetMonitor.GetPriorityTargets()
    local groupTargets = TargetMonitor.GetGroupTargets()

    -- Build situation context
    local situation = {
        hasEmergency = false,
        multipleHurt = 0,
    }

    for _, t in ipairs(allTargets) do
        if t.pctHP < Config.emergencyPct then
            situation.hasEmergency = true
        end
        if t.deficit > 0 then
            situation.multipleHurt = situation.multipleHurt + 1
        end
    end
    situation.multipleHurt = situation.multipleHurt > 1

    -- Priority 1: Emergency heals (anyone below threshold)
    for _, t in ipairs(allTargets) do
        if t.pctHP < Config.emergencyPct then
            local heal = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name)
                Analytics.RecordCriticalEvent(t.name, t.pctHP)
                return
            end
        end
    end

    -- Priority 2: Group heal check
    local useGroup, groupHeal = HealSelector.ShouldUseGroupHeal(allTargets)
    if useGroup and groupHeal then
        DeficitHealer.CastHeal(groupHeal.spell, mq.TLO.Me.Name())
        return
    end

    -- Priority 3: Priority targets (MT/MA)
    for _, t in ipairs(priorityTargets) do
        if t.deficit > 0 then
            local heal = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name)
                return
            end
        end
    end

    -- Priority 4: Group members
    for _, t in ipairs(groupTargets) do
        if t.deficit > 0 then
            local heal = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name)
                return
            end
        end
    end

    -- Priority 5: Proactive heals (HoTs/Promised when stable)
    if not situation.hasEmergency then
        for _, t in ipairs(priorityTargets) do
            local shouldHot, hotSpell = Proactive.ShouldApplyHot(t)
            if shouldHot then
                DeficitHealer.CastHeal(hotSpell, t.name)
                Proactive.RecordHot(t.name, hotSpell, 18)
                return
            end

            local shouldPromised, promisedSpell = Proactive.ShouldApplyPromised(t, situation)
            if shouldPromised then
                DeficitHealer.CastHeal(promisedSpell, t.name)
                Proactive.RecordPromised(t.name, promisedSpell, 18)
                return
            end
        end
    end
end

-- Register ImGui
mq.imgui.init('DeficitHealerUI', function()
    UI.Draw()
end)

-- Command binds
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

mq.bind('/dhui', function()
    UI.Toggle()
end)

-- Start the script
DeficitHealer.Init()

while DeficitHealer.running do
    DeficitHealer.ProcessHealing()
    mq.delay(100)  -- 100ms loop
    mq.doevents()
end

DeficitHealer.Shutdown()
