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
    shutdownCalled = false,  -- Guard against double shutdown
}

-- Track pending heal info for analytics (declared before event handler uses it)
local pendingHealInfo = nil

-- Track pending group heal info separately (group heals fire multiple events)
local pendingGroupHeal = nil  -- { spell, startTime, deficit, heals = {} }

-- Track when we first noticed each target needed healing (for reaction time)
local firstNoticedDeficit = {}  -- targetName -> { time, deficitPct }

-- Track last spell we cast (for manual cast learning)
local lastCastSpell = nil
local lastCastTime = 0

-- Event pattern for heal landing
-- Actual format: "You healed Targetname for 234 (1096) hit points by Spell Name."
mq.event('HealLanded', 'You healed #1# for #2# (#3#) hit points by #4#', function(line, target, amount, fullAmount, spell)
    -- First param is full line, then captures follow
    -- Use fullAmount for learning (the spell's actual healing power)
    local numAmount = tonumber(fullAmount) or tonumber(amount)
    if numAmount and spell then
        spell = spell:gsub('%.$', '')  -- Remove trailing period
        spell = spell:gsub(' %(Critical%)$', '')  -- Remove (Critical) suffix

        -- Check if we cast this spell (script-initiated or manual)
        -- This prevents tracking heals from other clerics with the same spells
        local isOurCast = false
        local isGroupHeal = false
        local isManualCast = false

        if pendingGroupHeal and pendingGroupHeal.spell == spell then
            isOurCast = true
            isGroupHeal = true
        elseif pendingHealInfo and pendingHealInfo.spell == spell then
            isOurCast = true
        elseif lastCastSpell == spell and (os.time() - lastCastTime) < 10 then
            -- Manual cast - we recently cast this spell (within 10 seconds)
            isOurCast = true
            isManualCast = true
        end

        if isOurCast then
            -- Always track for learning
            HealTracker.RecordHeal(spell, numAmount)

            if isGroupHeal then
                -- Accumulate group heal data - don't clear until timeout
                table.insert(pendingGroupHeal.heals, { target = target, amount = numAmount })
            elseif not isManualCast then
                -- Script-initiated single target heal - record analytics and clear pending info
                Analytics.RecordHeal(spell, numAmount, pendingHealInfo.deficit, pendingHealInfo.target)
                pendingHealInfo = nil
            end
            -- Manual casts only go to HealTracker for learning, not Analytics
        end
    end
end)

function DeficitHealer.Init()
    DeficitHealer.charName = mq.TLO.Me.Name()

    -- Load saved data
    local healData, analyticsHistory = Persistence.Load(DeficitHealer.charName)

    -- Initialize all modules
    Config.Load(DeficitHealer.charName)
    HealTracker.Init(healData, Config.learningWeight)
    TargetMonitor.Init(Config)
    HealSelector.Init(Config, HealTracker)
    Proactive.Init(Config, HealTracker, TargetMonitor)
    Analytics.Init(analyticsHistory)  -- Pass saved history to restore it
    UI.Init(Config, HealTracker, TargetMonitor, HealSelector, Analytics)

    DeficitHealer.running = true
    DeficitHealer.shutdownCalled = false  -- Reset shutdown guard for restart
    print('[DeficitHealer] Initialized for ' .. DeficitHealer.charName)
end

function DeficitHealer.Shutdown()
    -- Guard against double shutdown
    if DeficitHealer.shutdownCalled then return end
    DeficitHealer.shutdownCalled = true

    -- Save all data
    Persistence.Save(DeficitHealer.charName, HealTracker.GetData(), Analytics.GetHistory())
    Analytics.SaveSession()
    Config.Save(DeficitHealer.charName)

    DeficitHealer.running = false
    print('[DeficitHealer] Shutdown complete - data saved')
end

function DeficitHealer.CastHeal(spellName, targetName, deficit, expected)
    if DeficitHealer.casting then return false end

    -- Record reaction time if we have first noticed deficit for this target
    local noticed = firstNoticedDeficit[targetName]
    if noticed then
        local reactionMs = (os.clock() * 1000) - noticed.time
        Analytics.RecordReactionTime(noticed.deficitPct, reactionMs)
        firstNoticedDeficit[targetName] = nil
    end

    mq.cmdf('/target %s', targetName)
    mq.delay(100)
    mq.cmdf('/cast "%s"', spellName)

    DeficitHealer.casting = true
    HealSelector.SetLastAction({
        spell = spellName,
        target = targetName,
        expected = expected or 0,
        time = os.time()
    })

    -- Store pending heal info for analytics when the heal event fires
    pendingHealInfo = {
        spell = spellName,
        target = targetName,
        deficit = deficit or 0,
        expected = expected or 0,
        castTime = os.time()
    }

    return true
end

function DeficitHealer.ProcessHealing()
    -- Update target info
    TargetMonitor.Update()
    Proactive.Update()

    -- Check casting state
    if mq.TLO.Me.Casting() then
        DeficitHealer.casting = true
        -- Track what we're casting for manual cast detection
        local castingName = mq.TLO.Me.Casting.Name()
        if castingName then
            lastCastSpell = castingName
            lastCastTime = os.time()
        end
        return
    else
        DeficitHealer.casting = false
    end

    -- Check if pendingGroupHeal is stale (> 2 seconds old) and finalize it
    if pendingGroupHeal and (os.time() - pendingGroupHeal.startTime) > 2 then
        local totalHealed = 0
        for _, h in ipairs(pendingGroupHeal.heals) do
            totalHealed = totalHealed + h.amount
        end
        Analytics.RecordHeal(pendingGroupHeal.spell, totalHealed, pendingGroupHeal.deficit, 'Group')
        pendingGroupHeal = nil
    end

    local allTargets = TargetMonitor.GetAllTargets()
    local priorityTargets = TargetMonitor.GetPriorityTargets()
    local groupTargets = TargetMonitor.GetGroupTargets()

    -- Track when we first notice each target with a deficit (for reaction time)
    for _, t in ipairs(allTargets) do
        if t.deficit > 0 and not firstNoticedDeficit[t.name] then
            firstNoticedDeficit[t.name] = {
                time = os.clock() * 1000,  -- milliseconds
                deficitPct = (t.deficit / t.maxHP) * 100
            }
        elseif t.deficit == 0 then
            firstNoticedDeficit[t.name] = nil  -- Clear when healed
        end
    end

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
                DeficitHealer.CastHeal(heal.spell, t.name, t.deficit, heal.expected)
                Analytics.RecordCriticalEvent(t.name, t.pctHP)
                return
            end
        end
    end

    -- Priority 2: Group heal check
    local useGroup, groupHeal = HealSelector.ShouldUseGroupHeal(allTargets)
    if useGroup and groupHeal then
        -- For group heals, estimate total deficit from all hurt targets
        local totalDeficit = 0
        for _, t in ipairs(allTargets) do
            if t.deficit > 0 then totalDeficit = totalDeficit + t.deficit end
        end

        -- Set up pendingGroupHeal instead of pendingHealInfo for group heals
        -- This allows accumulating multiple heal events from the group heal
        pendingGroupHeal = {
            spell = groupHeal.spell,
            deficit = totalDeficit,
            startTime = os.time(),
            heals = {}
        }

        -- Cast the group heal (don't use DeficitHealer.CastHeal to avoid setting pendingHealInfo)
        if not DeficitHealer.casting then
            mq.cmdf('/target %s', mq.TLO.Me.Name())
            mq.delay(100)
            mq.cmdf('/cast "%s"', groupHeal.spell)

            DeficitHealer.casting = true
            HealSelector.SetLastAction({
                spell = groupHeal.spell,
                target = mq.TLO.Me.Name(),
                expected = groupHeal.expected * (groupHeal.targets or 1),
                time = os.time()
            })
        end
        return
    end

    -- Priority 3: Priority targets (MT/MA)
    for _, t in ipairs(priorityTargets) do
        if t.deficit > 0 then
            local heal = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name, t.deficit, heal.expected)
                return
            end
        end
    end

    -- Priority 4: Group members
    for _, t in ipairs(groupTargets) do
        if t.deficit > 0 then
            local heal = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name, t.deficit, heal.expected)
                return
            end
        end
    end

    -- Priority 5: Proactive heals (HoTs/Promised when stable)
    if not situation.hasEmergency then
        for _, t in ipairs(priorityTargets) do
            local shouldHot, hotSpell = Proactive.ShouldApplyHot(t)
            if shouldHot then
                -- Proactive heals don't have deficit context, pass 0
                DeficitHealer.CastHeal(hotSpell, t.name, 0, 0)
                Proactive.RecordHot(t.name, hotSpell, 18)
                return
            end

            local shouldPromised, promisedSpell = Proactive.ShouldApplyPromised(t, situation)
            if shouldPromised then
                -- Proactive heals don't have deficit context, pass 0
                DeficitHealer.CastHeal(promisedSpell, t.name, 0, 0)
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

mq.bind('/dhreset', function()
    HealTracker.Reset()
end)

-- Start the script
DeficitHealer.Init()

while DeficitHealer.running do
    DeficitHealer.ProcessHealing()
    mq.delay(100)  -- 100ms loop
    mq.doevents()
end

DeficitHealer.Shutdown()
