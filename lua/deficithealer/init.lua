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
local CombatAssessor = require('deficithealer.combatassessor')
local Analytics = require('deficithealer.analytics')
local UI = require('deficithealer.ui')
local Persistence = require('deficithealer.persistence')
local Logger = require('deficithealer.logger')

local DeficitHealer = {
    running = false,
    charName = mq.TLO.Me.Name(),
    casting = false,
    shutdownCalled = false,  -- Guard against double shutdown
    currentCast = nil,       -- { target, spell, isEmergency, startTime }
}

local SINGLE_HEAL_WINDOW_MS = 8000
local GROUP_HEAL_WINDOW_MS = 2500
local MANUAL_CAST_WINDOW_MS = 10000
local TICK_MS = 6000
local lastTickLogAtMs = 0
local lastSkipLogAt = {}
local MEZ_ANIMATIONS = {
    -- Combined set from rgmercs + muleassist.
    [1] = true,
    [5] = true,
    [6] = true,
    [17] = true,
    [26] = true,
    [27] = true,
    [32] = true,
    [43] = true,
    [44] = true,
    [45] = true,
    [71] = true,
    [72] = true,
    [80] = true,
    [82] = true,
    [111] = true,
    [112] = true,
    [129] = true,
    [134] = true,
    [135] = true,
}

local function normalizeText(value)
    if not value then
        return ''
    end
    if type(value) ~= 'string' then
        value = tostring(value)
    end
    return value:lower():gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
end

local function nowMs()
    local tloTime = mq.TLO.Time.MillisecondsSinceEpoch()
    if tloTime then
        if type(tloTime) == 'function' then
            local value = tloTime()
            if value then
                return value
            end
        elseif type(tloTime) == 'number' then
            return tloTime
        end
    end
    return os.time() * 1000
end

local function getSpellWindowMs(spellName, defaultWindowMs)
    local windowMs = defaultWindowMs
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() then
        local subcategory = normalizeText(spell.Subcategory())
        local durationTicks = tonumber(spell.Duration()) or 0
        if (subcategory == 'duration heals' or subcategory == 'delayed') and durationTicks > 0 then
            local durationMs = durationTicks * TICK_MS
            windowMs = math.max(windowMs, durationMs + 2000)
        end
    end
    return windowMs
end

local function getSpellMeta(spellName)
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then
        return nil
    end
    local mySpell = mq.TLO.Me.Spell(spellName)
    local myCastTime = nil
    if mySpell and mySpell() then
        myCastTime = mySpell.MyCastTime()
    end
    return {
        mana = tonumber(spell.Mana()) or 0,
        castTimeMs = tonumber(myCastTime) or tonumber(spell.CastTime()) or 0,
        recastTimeMs = tonumber(spell.RecastTime()) or 0,
        durationTicks = tonumber(spell.Duration()) or 0,
    }
end

local function getSpellDurationSec(spellName)
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() then
        local ticks = tonumber(spell.Duration()) or 0
        if ticks > 0 then
            return ticks * (TICK_MS / 1000)
        end
    end
    return 18
end

local function getHotTickCount(spellName)
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() then
        local ticks = tonumber(spell.Duration()) or 0
        if ticks > 0 then
            return ticks
        end
    end
    return 0
end

local function getHotExpectedTick(spellName, expected)
    local tick = tonumber(expected) or 0
    if tick <= 0 and HealTracker and HealTracker.GetExpectedHeal then
        tick = HealTracker.GetExpectedHeal(spellName) or 0
    end
    return tick
end

local function getHotExpectedTotals(spellName, expected)
    local tick = getHotExpectedTick(spellName, expected)
    local ticks = getHotTickCount(spellName)
    local total = (tick > 0 and ticks > 0) and (tick * ticks) or 0
    return tick, ticks, total
end

-- Track pending single-target casts
local pendingCasts = {}    -- targetName -> spellName -> { deficit, expected, castTimeMs, windowMs, expiresAtMs }
-- Track pending HoT casts (single target)
local pendingHotHeals = {} -- targetName -> spellName -> { deficit, expected, expectedTick, ticksTotal, expectedTotal, ticksSeen, expectedUsed, actualTotal, castTimeMs, windowMs, expiresAtMs }
-- Track pending group heal info separately (group heals fire multiple events)
local pendingGroupHeal = nil  -- { spell, startTimeMs, windowMs, deficit, targets = {}, heals = {} }

local function getIncomingHotRemaining(targetName)
    local spells = pendingHotHeals[targetName]
    if not spells then
        spells = {}
    end
    local now = nowMs()
    local total = 0
    local details = {}
    for spellName, info in pairs(spells) do
        local expectedTick = tonumber(info.expectedTick) or tonumber(info.expected) or 0
        if expectedTick <= 0 and HealTracker and HealTracker.GetExpectedHeal then
            expectedTick = tonumber(HealTracker.GetExpectedHeal(spellName)) or 0
        end
        local ticksTotal = tonumber(info.ticksTotal) or 0
        if expectedTick > 0 and ticksTotal > 0 then
            local castTimeMs = tonumber(info.castTimeMs) or now
            local elapsedMs = math.max(0, now - castTimeMs)
            local ticksElapsed = math.floor(elapsedMs / TICK_MS)
            local ticksRemaining = math.max(0, ticksTotal - ticksElapsed)
            local remaining = expectedTick * ticksRemaining
            total = total + remaining
            table.insert(details, string.format('%s:%d*%d=%d', tostring(spellName), expectedTick, ticksRemaining, remaining))
        end
    end
    if pendingGroupHeal and pendingGroupHeal.category == 'groupHot' and pendingGroupHeal.targets and pendingGroupHeal.targets[targetName] then
        local expectedTick = tonumber(pendingGroupHeal.expectedPerTarget) or 0
        local ticksTotal = getHotTickCount(pendingGroupHeal.spell)
        if expectedTick > 0 and ticksTotal > 0 then
            local elapsedMs = math.max(0, now - (pendingGroupHeal.startTimeMs or now))
            local ticksElapsed = math.floor(elapsedMs / TICK_MS)
            local ticksRemaining = math.max(0, ticksTotal - ticksElapsed)
            local remaining = expectedTick * ticksRemaining
            total = total + remaining
            table.insert(details, string.format('%s:%d*%d=%d', tostring(pendingGroupHeal.spell), expectedTick, ticksRemaining, remaining))
        end
    end
    return total, details
end

local function applyIncomingHot(targets)
    for _, t in ipairs(targets) do
        local remaining, details = getIncomingHotRemaining(t.name)
        t.incomingHotRemaining = remaining
        t.incomingHotDetails = details
    end
end

-- Track when we first noticed each target needed healing (for reaction time)
local firstNoticedDeficit = {}  -- targetName -> { time, deficitPct }

-- Track last spell we cast (for manual cast learning)
local lastCastSpell = nil
local lastCastTimeMs = 0

local getControlMetrics

local function normalizeTargetName(name)
    if not name then
        return nil
    end
    local lower = name:lower()
    if lower == 'you' or lower == 'yourself' then
        return mq.TLO.Me.Name()
    end
    return name
end

local function logInterrupt(reason)
    local now = nowMs()
    local action = HealSelector.GetLastAction and HealSelector.GetLastAction() or nil
    local spell = lastCastSpell
    local target = nil
    if type(action) == 'table' then
        if action.spell and (not spell or spell == '') then
            spell = action.spell
        end
        target = action.target
    end
    local sinceMs = (lastCastTimeMs and lastCastTimeMs > 0) and (now - lastCastTimeMs) or 0
    if not spell or spell == '' then
        Logger.Log('warn', string.format('INTERRUPT reason=%s spell=unknown sinceMs=%d', tostring(reason or 'interrupt'), sinceMs))
        return
    end
    Logger.Log('warn', string.format('INTERRUPT reason=%s spell=%s target=%s sinceMs=%d',
        tostring(reason or 'interrupt'), tostring(spell), tostring(target or ''), sinceMs))

    -- Clear pending entries so we don't mis-attribute other heals.
    if target and target ~= '' then
        if pendingCasts[target] and pendingCasts[target][spell] then
            pendingCasts[target][spell] = nil
            if next(pendingCasts[target]) == nil then pendingCasts[target] = nil end
        end
        if pendingHotHeals[target] and pendingHotHeals[target][spell] then
            pendingHotHeals[target][spell] = nil
            if next(pendingHotHeals[target]) == nil then pendingHotHeals[target] = nil end
        end
    end
    if pendingGroupHeal and pendingGroupHeal.spell == spell then
        pendingGroupHeal = nil
    end
end

local function logDecision(message)
    if Config and Config.debugLogging then
        print('[DeficitHealer] ' .. message)
    end
    local mobs = situation and situation.mobs or nil
    local mezzed = situation and situation.mezzed or nil
    local maPct = situation and situation.maPct or nil
    local healers = situation and situation.healers or nil
    if mobs == nil or mezzed == nil or healers == nil then
        mobs, mezzed, maPct, healers = getControlMetrics()
    end
    local maText = maPct and string.format('%.1f', maPct) or 'na'
    Logger.Log('info', string.format(
        'DECISION %s mobs100=%d mezzed100=%d maTargetPct=%s healers=%d',
        message, mobs, mezzed, maText, healers
    ))
end

local function formatTargetInfo(targetInfo)
    if not targetInfo then
        return ''
    end
    local pct = tonumber(targetInfo.pctHP) or 0
    local deficit = tonumber(targetInfo.deficit) or 0
    local cur = tonumber(targetInfo.currentHP) or 0
    local max = tonumber(targetInfo.maxHP) or 0
    local dps = tonumber(targetInfo.recentDps) or 0
    local role = tostring(targetInfo.role or '')
    local hotRemaining = tonumber(targetInfo.incomingHotRemaining) or 0
    local hotText = hotRemaining > 0 and string.format(' hotIn=%d', hotRemaining) or ''
    return string.format('hp=%d/%d pct=%.1f deficit=%d dps=%.0f role=%s%s', cur, max, pct, deficit, dps, role, hotText)
end

local function formatSpellMeta(meta)
    if not meta then
        return ''
    end
    local mana = tonumber(meta.mana) or 0
    local castMs = tonumber(meta.castTimeMs) or 0
    local recastMs = tonumber(meta.recastTimeMs) or 0
    return string.format('mana=%d castMs=%d recastMs=%d', mana, castMs, recastMs)
end

local function logDebug(message)
    Logger.Log('debug', message)
end

local function countNearbyMobs(radius)
    local r = tonumber(radius) or 100
    local total = 0
    local mezzed = 0
    if mq and mq.TLO and mq.TLO.SpawnCount then
        local filter = string.format('npc radius %d', r)
        total = tonumber(mq.TLO.SpawnCount(filter)()) or 0
        for i = 1, total do
            local spawn = mq.TLO.NearestSpawn(i, filter)
            if spawn and spawn() then
                local anim = spawn.Animation and spawn.Animation() or nil
                if anim and MEZ_ANIMATIONS[anim] then
                    mezzed = mezzed + 1
                end
            end
        end
    end
    return total, mezzed
end

local function getMainAssistTargetPct()
    local function resolveAssistTarget(value)
        if not value then return nil end
        if type(value) == 'string' then
            if value == '' then return nil end
            local spawn = mq.TLO.Spawn(value)
            if spawn and spawn() then
                return spawn
            end
            return nil
        end
        if type(value) == 'function' then
            if value() then
                return value
            end
            return nil
        end
        return value
    end

    local target = nil
    if mq.TLO.Me and mq.TLO.Me.GroupAssistTarget then
        target = resolveAssistTarget(mq.TLO.Me.GroupAssistTarget())
    end
    if not target and mq.TLO.Me and mq.TLO.Me.RaidAssistTarget then
        target = resolveAssistTarget(mq.TLO.Me.RaidAssistTarget(1))
    end
    if not target then return nil end
    local pct = target.PctHPs and target.PctHPs() or nil
    return tonumber(pct)
end

local function countGroupHealers()
    local count = 0
    local seen = {}
    local meName = mq.TLO.Me.Name()
    local meClass = mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName and mq.TLO.Me.Class.ShortName() or ''
    meClass = tostring(meClass):upper()

    if mq.TLO.Group and mq.TLO.Group.Members then
        local members = tonumber(mq.TLO.Group.Members()) or 0
        for i = 1, members do
            local member = mq.TLO.Group.Member(i)
            if member and member.Name and member.Name() then
                local name = member.Name()
                seen[name] = true
                local cls = member.Class and member.Class.ShortName and member.Class.ShortName() or ''
                if name == meName and (not cls or cls == '') then
                    cls = meClass
                end
                cls = tostring(cls):upper()
                if cls == 'SHM' or cls == 'DRU' then
                    count = count + 1
                end
            end
        end
    end

    if meName and not seen[meName] then
        if meClass == 'SHM' or meClass == 'DRU' then
            count = count + 1
        end
    end

    return count
end

getControlMetrics = function()
    local mobs, mezzed = countNearbyMobs(100)
    local maPct = getMainAssistTargetPct()
    local healers = countGroupHealers()
    return mobs, mezzed, maPct, healers
end

-- Duck (cancel) the current spell using /stopcast
local function duckSpell(reason)
    local cast = DeficitHealer.currentCast
    local target = cast and cast.target or 'unknown'
    local spell = cast and cast.spell or 'unknown'
    local initialPct = cast and cast.initialPct or 0
    local threshold = cast and cast.duckThreshold or 0

    Logger.Log('info', string.format(
        'DUCK target=%s %s (startedAt=%.1f%% duckThreshold=%d%%)',
        target, tostring(reason), initialPct, threshold
    ))

    mq.cmd('/stopcast')

    -- Clear pending cast info since we ducked
    if DeficitHealer.currentCast and DeficitHealer.currentCast.target then
        local castTarget = DeficitHealer.currentCast.target
        local castSpell = DeficitHealer.currentCast.spell
        if pendingCasts[castTarget] and pendingCasts[castTarget][castSpell] then
            pendingCasts[castTarget][castSpell] = nil
            if next(pendingCasts[castTarget]) == nil then
                pendingCasts[castTarget] = nil
            end
        end
    end

    DeficitHealer.currentCast = nil
    DeficitHealer.casting = false
end

-- Check if we should duck the current heal (target HP recovered)
local function isSquishyByClass(targetName, targetSpawn)
    local cfg = Config
    local classShort = ''
    if targetSpawn and targetSpawn.Class and targetSpawn.Class.ShortName then
        classShort = tostring(targetSpawn.Class.ShortName() or '')
    elseif targetName == mq.TLO.Me.Name() then
        classShort = tostring(mq.TLO.Me.Class.ShortName() or '')
    end
    classShort = classShort:upper()
    if cfg and cfg.squishyClasses and #cfg.squishyClasses > 0 then
        for _, cls in ipairs(cfg.squishyClasses) do
            if classShort == tostring(cls):upper() then
                return true, classShort
            end
        end
    end
    return false, classShort
end

local function getDuckThreshold(targetName, targetSpawn, isHot, isEmergency)
    local cfg = Config
    local isSquishy, classShort = isSquishyByClass(targetName, targetSpawn)
    local minDeficitPct = cfg.minHealPct or 10
    if isHot then
        minDeficitPct = cfg.hotMinDeficitPct or minDeficitPct
        if not isSquishy and cfg.nonSquishyHotMinDeficitPct then
            minDeficitPct = math.max(minDeficitPct, cfg.nonSquishyHotMinDeficitPct)
        end
    elseif not isSquishy and cfg.nonSquishyMinHealPct then
        minDeficitPct = math.max(minDeficitPct, cfg.nonSquishyMinHealPct)
    end

    local threshold = 100 - minDeficitPct
    if isEmergency and cfg.duckEmergencyThreshold then
        threshold = math.min(threshold, cfg.duckEmergencyThreshold)
    elseif isHot and cfg.duckHotThreshold then
        threshold = math.min(threshold, cfg.duckHotThreshold)
    elseif cfg.duckHpThreshold then
        threshold = math.min(threshold, cfg.duckHpThreshold)
    end

    local buffer = tonumber(cfg.duckBufferPct) or 0
    local effective = threshold + buffer
    return threshold, effective, minDeficitPct, isSquishy, classShort, buffer
end

local function shouldDuckHeal()
    if not Config.duckEnabled then
        return false, nil
    end

    local cast = DeficitHealer.currentCast
    if not cast or not cast.target then
        return false, nil
    end

    -- Get current HP of the target
    local spawn = mq.TLO.Spawn('pc ' .. cast.target)
    if not spawn or not spawn() then
        return false, nil
    end
    local currentPct = tonumber(spawn.PctHPs()) or 0

    local threshold, effectiveThreshold, minDeficitPct, isSquishy, classShort, buffer = getDuckThreshold(
        cast.target,
        spawn,
        cast.isHot,
        cast.isEmergency
    )

    -- Calculate cast elapsed time
    local elapsed = cast.startTime and (nowMs() - cast.startTime) or 0
    local hpDelta = currentPct - (cast.initialPct or 0)

    if currentPct >= effectiveThreshold then
        local reason = string.format(
            'hp=%.1f%% threshold=%d%% buffer=%.1f%% minDeficitPct=%.1f class=%s squishy=%s startHp=%.1f%% delta=%+.1f%% elapsed=%dms spell=%s emergency=%s hot=%s',
            currentPct, threshold, buffer, minDeficitPct, tostring(classShort or ''), tostring(isSquishy),
            cast.initialPct or 0, hpDelta, elapsed, cast.spell or 'unknown',
            tostring(cast.isEmergency), tostring(cast.isHot)
        )
        return true, reason
    end

    -- Log check at trace level (not ducking but shows monitoring is happening)
    Logger.Log('trace', string.format(
        'DUCK_CHECK target=%s hp=%.1f%% threshold=%d%% buffer=%.1f%% minDeficitPct=%.1f class=%s squishy=%s startHp=%.1f%% delta=%+.1f%% elapsed=%dms spell=%s - NOT ducking',
        cast.target, currentPct, threshold, buffer, minDeficitPct, tostring(classShort or ''), tostring(isSquishy),
        cast.initialPct or 0, hpDelta, elapsed, cast.spell or 'unknown'
    ))

    return false, nil
end

local function logSkip(targetInfo, reason, source)
    if not targetInfo then return end
    if not Logger.ShouldLog('debug') then return end
    local throttle = (Config and Config.fileLogSkipThrottleMs) or 2000
    local key = string.format('%s|%s|%s', tostring(targetInfo.name), tostring(reason), tostring(source))
    local now = nowMs()
    local lastAt = lastSkipLogAt[key] or 0
    if (now - lastAt) < throttle then
        return
    end
    lastSkipLogAt[key] = now
    local mobs, mezzed, maPct, healers = getControlMetrics()
    local maText = maPct and string.format('%.1f', maPct) or 'na'
    logDebug(string.format(
        'SKIP source=%s target=%s reason=%s %s mobs100=%d mezzed100=%d maTargetPct=%s healers=%d',
        tostring(source or 'unknown'),
        tostring(targetInfo.name or ''),
        tostring(reason or 'unknown'),
        formatTargetInfo(targetInfo),
        mobs,
        mezzed,
        maText,
        healers
    ))
end

local function logTickSummary(allTargets, situation)
    if not Logger.ShouldLog('debug') then return end
    local intervalMs = (Config and Config.fileLogTickMs) or 0
    if intervalMs <= 0 then return end
    local now = nowMs()
    if (now - lastTickLogAtMs) < intervalMs then return end
    lastTickLogAtMs = now

    local targets = #allTargets
    local emergency = situation and situation.hasEmergency and 'true' or 'false'
    local multiple = situation and situation.multipleHurt and 'true' or 'false'
    local efficiency = Analytics.GetEfficiency and Analytics.GetEfficiency() or 0
    local overheal = Analytics.GetOverhealPct and Analytics.GetOverhealPct() or 0

    local top = {}
    local sorted = {}
    for _, t in ipairs(allTargets) do
        table.insert(sorted, t)
    end
    table.sort(sorted, function(a, b) return (a.deficit or 0) > (b.deficit or 0) end)
    for i = 1, math.min(3, #sorted) do
        local t = sorted[i]
        table.insert(top, string.format('%s:%d(%.1f%%)', tostring(t.name or ''), tonumber(t.deficit) or 0, tonumber(t.pctHP) or 0))
    end

    local topDps = {}
    local sortedDps = {}
    for _, t in ipairs(allTargets) do
        table.insert(sortedDps, t)
    end
    table.sort(sortedDps, function(a, b) return (a.recentDps or 0) > (b.recentDps or 0) end)
    for i = 1, math.min(3, #sortedDps) do
        local t = sortedDps[i]
        local dps = tonumber(t.recentDps) or 0
        if dps > 0 then
            table.insert(topDps, string.format('%s:%.0f', tostring(t.name or ''), dps))
        end
    end
    local dpsText = #topDps > 0 and (' dpsTop=[' .. table.concat(topDps, ',') .. ']') or ''

    local mobs, mezzed, maPct, healers = getControlMetrics()
    local maText = maPct and string.format('%.1f', maPct) or 'na'

    -- Combat assessment info
    local combatText = ''
    if situation and situation.combatAssessment then
        local ca = situation.combatAssessment
        combatText = string.format(' combat=[phase=%s ttk=%.0fs survival=%s dpsPct=%.1f%%]',
            ca.fightPhase or 'none',
            ca.estimatedDurationSec or 0,
            tostring(ca.survivalMode or false),
            ca.dpsPercent or 0
        )
    end

    logDebug(string.format(
        'TICK targets=%d emergency=%s multipleHurt=%s efficiency=%.1f overheal=%.1f mobs100=%d mezzed100=%d maTargetPct=%s healers=%d top=[%s]%s%s',
        targets, emergency, multiple, efficiency, overheal, mobs, mezzed, maText, healers, table.concat(top, ','), dpsText, combatText
    ))
end

local lastDpsValidationLogAtMs = 0

local function logDpsValidation(allTargets)
    if not Logger.ShouldLog('debug') then return end
    local intervalMs = (Config and Config.dpsValidationLogMs) or 5000
    if intervalMs <= 0 then return end
    local now = nowMs()
    if (now - lastDpsValidationLogAtMs) < intervalMs then return end
    lastDpsValidationLogAtMs = now

    -- Get validation data for all targets with activity
    local validations = TargetMonitor.GetAllDpsValidation()
    if #validations == 0 then return end

    -- Log each target's DPS validation with deficit comparison
    for _, v in ipairs(validations) do
        -- Find matching target info for deficit comparison
        local deficit = 0
        local pctHP = 100
        for _, t in ipairs(allTargets) do
            if t.name == v.name then
                deficit = t.deficit or 0
                pctHP = t.pctHP or 100
                break
            end
        end

        -- Calculate expected damage over window vs actual deficit
        -- Note: deficit is current missing HP, not damage over time
        -- A large discrepancy between logTotal and hpTotal suggests healing from others
        local healedByOthers = math.max(0, v.logTotal - v.hpTotal)

        Logger.Log('debug', string.format(
            'DPS_VALIDATION target=%s hpDps=%.0f logDps=%.0f combinedDps=%.0f discrepancy=%+.0f%% hpTotal=%.0f logTotal=%.0f healedByOthers=%.0f deficit=%d pctHP=%.1f window=%ds',
            v.name,
            v.hpDps,
            v.logDps,
            v.combinedDps,
            v.discrepancy,
            v.hpTotal,
            v.logTotal,
            healedByOthers,
            deficit,
            pctHP,
            v.windowSec
        ))
    end

    -- Summary line with totals
    local totalHpDps = 0
    local totalLogDps = 0
    local totalDeficit = 0
    for _, v in ipairs(validations) do
        totalHpDps = totalHpDps + v.hpDps
        totalLogDps = totalLogDps + v.logDps
    end
    for _, t in ipairs(allTargets) do
        totalDeficit = totalDeficit + (t.deficit or 0)
    end

    local avgDiscrepancy = 0
    if totalHpDps > 0 then
        avgDiscrepancy = ((totalLogDps - totalHpDps) / totalHpDps) * 100
    elseif totalLogDps > 0 then
        avgDiscrepancy = 100
    end

    Logger.Log('debug', string.format(
        'DPS_VALIDATION_SUMMARY targets=%d totalHpDps=%.0f totalLogDps=%.0f avgDiscrepancy=%+.0f%% totalDeficit=%d',
        #validations,
        totalHpDps,
        totalLogDps,
        avgDiscrepancy,
        totalDeficit
    ))
end

local function logHealEvent(spell, target, actual, potential, deficit, expected, flags, isCrit)
    local actualNum = tonumber(actual) or 0
    local potentialNum = tonumber(potential) or actualNum
    local deficitNum = tonumber(deficit) or 0
    local expectedNum = tonumber(expected) or 0
    local overheal = math.max(0, potentialNum - actualNum)
    local eff = potentialNum > 0 and (actualNum / potentialNum) * 100 or 0
    local flagText = ''
    if flags and type(flags) == 'table' then
        local parts = {}
        for k, v in pairs(flags) do
            table.insert(parts, string.format('%s=%s', tostring(k), tostring(v)))
        end
        if #parts > 0 then
            flagText = ' ' .. table.concat(parts, ' ')
        end
    end
    local mobs, mezzed, maPct, healers = getControlMetrics()
    local maText = maPct and string.format('%.1f', maPct) or 'na'
    local critText = isCrit and ' crit=true' or ''

    -- Include spell's crit stats if available
    local critStats = ''
    local stats = HealTracker.GetDetailedStats(spell)
    if stats and stats.totalCount >= 3 then
        critStats = string.format(' baseAvg=%.0f critRate=%.1f%% expected=%.0f',
            stats.baseAvg or 0,
            stats.critPct or 0,
            stats.expected or 0
        )
    end

    Logger.Log('info', string.format(
        'HEAL spell=%s target=%s actual=%d potential=%d overheal=%d eff=%.1f deficitAtCast=%d expected=%d mobs100=%d mezzed100=%d maTargetPct=%s healers=%d%s%s%s',
        tostring(spell or ''),
        tostring(target or ''),
        actualNum,
        potentialNum,
        overheal,
        eff,
        deficitNum,
        expectedNum,
        mobs,
        mezzed,
        maText,
        healers,
        flagText,
        critText,
        critStats
    ))
end

local function recordLogDamage(targetName, amount)
    if not Config or not Config.useLogDps then
        return
    end
    local numAmount = tonumber(amount)
    if not numAmount or numAmount <= 0 then
        return
    end
    local normalized = normalizeTargetName(targetName)
    if normalized and TargetMonitor.IsGroupMemberName and TargetMonitor.IsGroupMemberName(normalized) then
        TargetMonitor.RecordLogDamage(normalized, numAmount)
    end
end

local function recordMobDamage(attackerName, amount)
    local numAmount = tonumber(amount)
    if not numAmount or numAmount <= 0 then
        return
    end
    if not attackerName or attackerName == '' then
        return
    end
    -- Skip if attacker is a player character (we only want mob DPS)
    local pcSpawn = mq.TLO.Spawn('pc =' .. attackerName)
    if pcSpawn and pcSpawn() then
        return
    end
    -- Record the damage dealt by this mob
    TargetMonitor.RecordMobDamage(attackerName, numAmount)
end

local lastHealLine = nil
local lastHealLineTimeMs = 0

local function shouldSkipHealLine(line)
    if not line or line == '' then
        return false
    end
    local now = nowMs()
    if line == lastHealLine and (now - lastHealLineTimeMs) < 200 then
        return true
    end
    lastHealLine = line
    lastHealLineTimeMs = now
    return false
end

-- Debug: capture all heal messages to diagnose format issues
-- This logs at trace level so it's only visible when fileLogLevel = 'trace'
mq.event('HealDebug', '#*#healed#*#hit points#*#', function(line)
    Logger.Log('trace', 'HEAL_RAW: ' .. tostring(line))
end)

local function handleHealLanded(line, target, amount, fullAmount, spell)
    if shouldSkipHealLine(line) then
        return
    end
    -- Use fullAmount for learning (the spell's actual healing power)
    local actualAmount = tonumber(amount)
    local fullAmountNum = tonumber(fullAmount)
    local learnAmount = fullAmountNum or actualAmount
    if learnAmount and spell then
        spell = spell:gsub('%.$', '')  -- Remove trailing period
        -- Detect critical heal before stripping the suffix
        local isCrit = spell:match(' %(Critical%)$') ~= nil
        spell = spell:gsub(' %(Critical%)$', '')  -- Remove (Critical) suffix
        if target then
            target = target:gsub('%s+over time$', '')
        end
        target = normalizeTargetName(target)

        local spellInfo = mq.TLO.Spell(spell)
        local subcategory = spellInfo and spellInfo() and normalizeText(spellInfo.Subcategory()) or ''
        local isHotSpell = subcategory == 'duration heals'

        -- Check if we cast this spell (script-initiated or manual)
        -- This prevents tracking heals from other clerics with the same spells
        local isOurCast = false
        local isGroupHeal = false
        local isManualCast = false
        local now = nowMs()

        if pendingGroupHeal and pendingGroupHeal.spell == spell then
            local withinWindow = (now - pendingGroupHeal.startTimeMs) <= pendingGroupHeal.windowMs
            if withinWindow then
                isOurCast = true
                isGroupHeal = true
            end
        elseif isHotSpell and pendingHotHeals[target] and pendingHotHeals[target][spell] then
            local hotInfo = pendingHotHeals[target][spell]
            if now <= hotInfo.expiresAtMs then
                isOurCast = true
            end
        elseif pendingCasts[target] and pendingCasts[target][spell] then
            local castInfo = pendingCasts[target][spell]
            if now <= castInfo.expiresAtMs then
                isOurCast = true
            end
        elseif lastCastSpell == spell and (now - lastCastTimeMs) <= MANUAL_CAST_WINDOW_MS then
            -- Manual cast - we recently cast this spell (within 10 seconds)
            isOurCast = true
            isManualCast = true
            if isHotSpell then
                local expectedTick, ticksTotal, expectedTotal = getHotExpectedTotals(spell, 0)
                local windowMs = getSpellWindowMs(spell, SINGLE_HEAL_WINDOW_MS)
                pendingHotHeals[target] = pendingHotHeals[target] or {}
                pendingHotHeals[target][spell] = {
                    deficit = 0,
                    expected = expectedTick,
                    expectedTick = expectedTick,
                    ticksTotal = ticksTotal,
                    expectedTotal = expectedTotal,
                    ticksSeen = 0,
                    expectedUsed = 0,
                    actualTotal = 0,
                    manual = true,
                    castTimeMs = now,
                    windowMs = windowMs,
                    expiresAtMs = now + windowMs,
                }
            end
        end

        if isOurCast and Config.IsConfiguredSpell(spell) then
            -- Track for learning (only configured spells), including crit status
            HealTracker.RecordHeal(spell, learnAmount, isCrit)
            local deficitAtCast = 0
            local expectedAtCast = 0
            if isGroupHeal then
                deficitAtCast = pendingGroupHeal and pendingGroupHeal.targetDeficits and pendingGroupHeal.targetDeficits[target] or 0
                expectedAtCast = pendingGroupHeal and pendingGroupHeal.expectedPerTarget or 0
            elseif isHotSpell then
                local hotInfo = pendingHotHeals[target] and pendingHotHeals[target][spell]
                deficitAtCast = hotInfo and hotInfo.deficit or 0
                expectedAtCast = hotInfo and hotInfo.expected or 0
            else
                local castInfo = pendingCasts[target] and pendingCasts[target][spell]
                deficitAtCast = castInfo and castInfo.deficit or 0
                expectedAtCast = castInfo and castInfo.expected or 0
            end

            if isGroupHeal then
                -- Accumulate group heal data - don't clear until timeout
                if pendingGroupHeal.targets and pendingGroupHeal.targets[target] then
                    table.insert(pendingGroupHeal.heals, {
                        target = target,
                        amount = actualAmount or learnAmount,
                        full = learnAmount,
                    })
                end
                if not isManualCast then
                    logHealEvent(spell, target, actualAmount or learnAmount, learnAmount, deficitAtCast, expectedAtCast, {
                        group = true,
                        category = pendingGroupHeal and pendingGroupHeal.category or 'group',
                    }, isCrit)
                end
            elseif isHotSpell then
                if not isManualCast then
                    local hotInfo = pendingHotHeals[target] and pendingHotHeals[target][spell]
                    if not hotInfo then
                        Logger.Log('debug', string.format('HOT_TICK_ORPHAN spell=%s target=%s', tostring(spell or ''), tostring(target or '')))
                    end
                    local deficit = hotInfo and hotInfo.deficit or 0
                    local actualValue = actualAmount or learnAmount
                    if hotInfo then
                        hotInfo.ticksSeen = (hotInfo.ticksSeen or 0) + 1
                        hotInfo.actualTotal = (hotInfo.actualTotal or 0) + (actualValue or 0)
                        if (hotInfo.expectedTick or 0) <= 0 and learnAmount and learnAmount > 0 then
                            hotInfo.expectedTick = learnAmount
                            if hotInfo.ticksTotal and hotInfo.ticksTotal > 0 then
                                hotInfo.expectedTotal = hotInfo.expectedTick * hotInfo.ticksTotal
                            end
                        end
                        local expectedPerTick = hotInfo.expectedTick or 0
                        if expectedPerTick > 0 then
                            hotInfo.expectedUsed = (hotInfo.expectedUsed or 0) + expectedPerTick
                        elseif learnAmount and learnAmount > 0 then
                            hotInfo.expectedUsed = (hotInfo.expectedUsed or 0) + learnAmount
                        end
                    end
                    Analytics.RecordHotTick(actualValue)
                    Analytics.RecordHeal(spell, actualValue, learnAmount, deficit, target)
                    logHealEvent(spell, target, actualValue, learnAmount, deficitAtCast, expectedAtCast, { hot = true }, isCrit)
                end
            elseif not isManualCast then
                -- Script-initiated single target heal - record analytics and clear pending info
                local castInfo = pendingCasts[target] and pendingCasts[target][spell]
                if castInfo then
                    Analytics.RecordHeal(spell, actualAmount or learnAmount, learnAmount, castInfo.deficit, target)
                    logHealEvent(spell, target, actualAmount or learnAmount, learnAmount, deficitAtCast, expectedAtCast, { hot = false }, isCrit)
                    pendingCasts[target][spell] = nil
                    if next(pendingCasts[target]) == nil then
                        pendingCasts[target] = nil
                    end
                end
            end
            -- Manual casts only go to HealTracker for learning, not Analytics
        end
    end
end

-- Event patterns for heal landing (multiple variants across logs/clients)
mq.event('HealLanded', 'You healed #1# for #2# (#3#) hit points by #4#', function(line, target, amount, fullAmount, spell)
    handleHealLanded(line, target, amount, fullAmount, spell)
end)
mq.event('HealLandedNoFull', 'You healed #1# for #2# hit points by #3#', function(line, target, amount, spell)
    handleHealLanded(line, target, amount, nil, spell)
end)
mq.event('HealLandedHave', 'You have healed #1# for #2# (#3#) hit points by #4#', function(line, target, amount, fullAmount, spell)
    handleHealLanded(line, target, amount, fullAmount, spell)
end)
mq.event('HealLandedHaveNoFull', 'You have healed #1# for #2# hit points by #3#', function(line, target, amount, spell)
    handleHealLanded(line, target, amount, nil, spell)
end)
mq.event('HealLandedYour', 'Your #1# heals #2# for #3# hit points', function(line, spell, target, amount)
    handleHealLanded(line, target, amount, nil, spell)
end)

-- Cast interruption / fizzle tracking
mq.event('SpellInterrupted', 'Your spell is interrupted.', function(line)
    logInterrupt('interrupt')
end)
mq.event('SpellInterruptedAlt', 'Your spell has been interrupted.', function(line)
    logInterrupt('interrupt')
end)
mq.event('SpellInterruptedCasting', 'Your casting has been interrupted.', function(line)
    logInterrupt('interrupt')
end)
mq.event('SpellFizzle', 'Your spell fizzles!', function(line)
    logInterrupt('fizzle')
end)

-- Log-based damage tracking (hybrid DPS)
-- Handlers for damage taken by self and group members, plus mob DPS tracking

-- Helper for "You were [verbed]" passive voice patterns
-- Note: MQ events pass full line as first param, then captures
local function onDamageToYou(line, attacker, amount)
    recordLogDamage(mq.TLO.Me.Name(), amount)
    recordMobDamage(attacker, amount)
end

-- Helper for "[Attacker] [verbs] [Target]" active voice patterns
local function onDamageToOther(line, attacker, target, amount)
    recordLogDamage(target, amount)
    recordMobDamage(attacker, amount)
end

-- Hit patterns (existing)
mq.event('DamageHitYou', 'You were hit by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageHitYouAlt', 'You are hit by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageHitOther', '#1# hit#*# #2# for #3# point#*# of damage.', onDamageToOther)
mq.event('DamageHitYouShort', 'You were hit by #1# for #2# damage.', onDamageToYou)
mq.event('DamageHitOtherShort', '#1# hit#*# #2# for #3# damage.', onDamageToOther)

-- Bash patterns
mq.event('DamageBashYou', 'You were bashed by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageBashOther', '#1# bash#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Kick patterns
mq.event('DamageKickYou', 'You were kicked by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageKickOther', '#1# kick#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Slash patterns
mq.event('DamageSlashYou', 'You were slashed by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageSlashOther', '#1# slash#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Pierce patterns
mq.event('DamagePierceYou', 'You were pierced by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamagePierceOther', '#1# pierce#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Crush patterns
mq.event('DamageCrushYou', 'You were crushed by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageCrushOther', '#1# crush#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Punch patterns
mq.event('DamagePunchYou', 'You were punched by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamagePunchOther', '#1# punch#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Strike patterns
mq.event('DamageStrikeYou', 'You were struck by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageStrikeOther', '#1# strike#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Bite patterns
mq.event('DamageBiteYou', 'You were bitten by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageBiteOther', '#1# bite#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Claw patterns
mq.event('DamageClawYou', 'You were clawed by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageClawOther', '#1# claw#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Gore patterns
mq.event('DamageGoreYou', 'You were gored by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageGoreOther', '#1# gore#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Maul patterns
mq.event('DamageMaulYou', 'You were mauled by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageMaulOther', '#1# maul#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Slam patterns
mq.event('DamageSlamYou', 'You were slammed by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageSlamOther', '#1# slam#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Smash patterns
mq.event('DamageSmashYou', 'You were smashed by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageSmashOther', '#1# smash#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Sting patterns
mq.event('DamageStingYou', 'You were stung by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageStingOther', '#1# sting#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Rend patterns
mq.event('DamageRendYou', 'You were rent by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageRendOther', '#1# rend#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Backstab patterns
mq.event('DamageBackstabYou', 'You were backstabbed by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageBackstabOther', '#1# backstab#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Frenzy patterns
mq.event('DamageFrenzyYou', 'You were hit by frenzied blows from #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageFrenzyOther', '#1# frenzies on #2# for #3# point#*# of damage.', onDamageToOther)

-- Ranged/shoot patterns
mq.event('DamageShootYou', 'You were shot by #1# for #2# point#*# of damage.', onDamageToYou)
mq.event('DamageShootOther', '#1# shoot#*# #2# for #3# point#*# of damage.', onDamageToOther)

-- Spell/ability damage from mobs (e.g., "Vander has taken 780 damage from Limbfreeze Breath by Kangur Vafta Veor")
mq.event('DamageSpellFromMob', '#1# has taken #2# damage from #3# by #4#', function(line, target, amount, spell, attacker)
    recordLogDamage(target, amount)
    recordMobDamage(attacker, amount)
end)

-- "You have taken X damage from Spell by Mob" format for self
mq.event('DamageSpellFromMobYou', 'You have taken #1# damage from #2# by #3#', function(line, amount, spell, attacker)
    recordLogDamage(mq.TLO.Me.Name(), amount)
    recordMobDamage(attacker, amount)
end)

-- Damage shield damage (mob DS hurting players)
-- Format: "Player is burned/chilled/tormented/etc by Mob's flames for X points of non-melee damage."
mq.event('DamageDS', '#1# is #*# by #2# for #3# point#*# of non-melee damage.', function(line, target, dsSource, amount)
    -- dsSource is like "a mob's flames" - extract mob name before "'s"
    local attacker = dsSource and dsSource:match("^(.+)'s ") or nil
    recordLogDamage(target, amount)
    if attacker then recordMobDamage(attacker, amount) end
end)

-- Non-melee (spells/procs) - no attacker name available
mq.event('DamageHitYouNonMelee', 'You were hit by non-melee for #1# damage.', function(line, amount)
    recordLogDamage(mq.TLO.Me.Name(), amount)
end)
mq.event('DamageHitYouNonMeleeAlt', 'You are hit by non-melee for #1# damage.', function(line, amount)
    recordLogDamage(mq.TLO.Me.Name(), amount)
end)

-- Falling damage - no mob involved
mq.event('DamageFallingYou', 'YOU were injured by falling.', function(line)
    recordLogDamage(mq.TLO.Me.Name(), 1)
end)
mq.event('DamageFallingOther', '#1# was injured by falling.', function(line, target)
    recordLogDamage(target, 1)
end)

local function addPendingCast(spellName, targetName, deficit, expected)
    local windowMs = getSpellWindowMs(spellName, SINGLE_HEAL_WINDOW_MS)
    pendingCasts[targetName] = pendingCasts[targetName] or {}
    pendingCasts[targetName][spellName] = {
        deficit = deficit or 0,
        expected = expected or 0,
        castTimeMs = nowMs(),
        windowMs = windowMs,
        expiresAtMs = nowMs() + windowMs,
    }
end

local finalizeHot

local function addPendingHot(spellName, targetName, deficit, expected)
    local existing = pendingHotHeals[targetName] and pendingHotHeals[targetName][spellName]
    if existing then
        finalizeHot(targetName, spellName, existing, 'refresh')
    end
    local expectedTick, ticksTotal, expectedTotal = getHotExpectedTotals(spellName, expected)
    local windowMs = getSpellWindowMs(spellName, SINGLE_HEAL_WINDOW_MS)
    local now = nowMs()
    pendingHotHeals[targetName] = pendingHotHeals[targetName] or {}
    pendingHotHeals[targetName][spellName] = {
        deficit = deficit or 0,
        expected = expectedTick,
        expectedTick = expectedTick,
        ticksTotal = ticksTotal,
        expectedTotal = expectedTotal,
        ticksSeen = 0,
        expectedUsed = 0,
        actualTotal = 0,
        castTimeMs = now,
        windowMs = windowMs,
        expiresAtMs = now + windowMs,
    }
    if expectedTotal > 0 then
        Logger.Log('info', string.format(
            'HOT_CAST spell=%s target=%s expectedTick=%d ticks=%d expectedTotal=%d deficitAtCast=%d',
            tostring(spellName or ''),
            tostring(targetName or ''),
            expectedTick,
            ticksTotal,
            expectedTotal,
            tonumber(deficit) or 0
        ))
    end
end

finalizeHot = function(targetName, spellName, info, reason)
    if not info then
        return
    end
    local expectedTick = tonumber(info.expectedTick) or 0
    local ticksTotal = tonumber(info.ticksTotal) or 0
    local ticksSeen = tonumber(info.ticksSeen) or 0
    local actualTotal = tonumber(info.actualTotal) or 0
    local expectedTotal = tonumber(info.expectedTotal) or 0
    local expectedUsed = tonumber(info.expectedUsed) or 0
    if expectedUsed <= 0 and expectedTick > 0 and ticksSeen > 0 then
        expectedUsed = expectedTick * ticksSeen
    end
    if expectedTotal <= 0 and expectedTick > 0 and ticksTotal > 0 then
        expectedTotal = expectedTick * ticksTotal
    end
    local missingTicks = (ticksTotal > 0) and math.max(0, ticksTotal - ticksSeen) or 0
    local missingPotential = 0
    if expectedTotal > expectedUsed then
        missingPotential = expectedTotal - expectedUsed
    end

    if not info.manual and missingTicks > 0 then
        Analytics.RecordHotMissed(missingTicks)
    end
    if not info.manual and missingPotential > 0 then
        Analytics.RecordHeal(spellName, 0, missingPotential, 0, targetName)
    end

    if expectedTotal > 0 then
        local eff = expectedTotal > 0 and (actualTotal / expectedTotal) * 100 or 0
        local reasonText = (reason and reason ~= '') and (' reason=' .. tostring(reason)) or ''
        local manualText = info.manual and ' manual=true' or ''
        Logger.Log('info', string.format(
            'HOT_SUMMARY spell=%s target=%s ticks=%d/%d expectedTick=%d expectedTotal=%d actualTotal=%d missingTicks=%d missingPotential=%d eff=%.1f deficitAtCast=%d%s%s',
            tostring(spellName or ''),
            tostring(targetName or ''),
            ticksSeen,
            ticksTotal,
            expectedTick,
            expectedTotal,
            actualTotal,
            missingTicks,
            missingPotential,
            eff,
            tonumber(info.deficit) or 0,
            reasonText,
            manualText
        ))
    end
end

local function cleanupPending()
    local now = nowMs()
    for targetName, spells in pairs(pendingCasts) do
        for spellName, info in pairs(spells) do
            if now > info.expiresAtMs then
                spells[spellName] = nil
            end
        end
        if next(spells) == nil then
            pendingCasts[targetName] = nil
        end
    end

    for targetName, spells in pairs(pendingHotHeals) do
        for spellName, info in pairs(spells) do
            if now > info.expiresAtMs then
                finalizeHot(targetName, spellName, info, 'expired')
                spells[spellName] = nil
            end
        end
        if next(spells) == nil then
            pendingHotHeals[targetName] = nil
        end
    end
end

local function recordReactionForTargets(targets)
    local earliest = nil
    for name in pairs(targets) do
        local noticed = firstNoticedDeficit[name]
        if noticed and (not earliest or noticed.time < earliest.time) then
            earliest = noticed
        end
    end
    if earliest then
        local reactionMs = nowMs() - earliest.time
        Analytics.RecordReactionTime(earliest.deficitPct, reactionMs)
        for name in pairs(targets) do
            firstNoticedDeficit[name] = nil
        end
    end
end

function DeficitHealer.Init()
    DeficitHealer.charName = mq.TLO.Me.Name()

    -- Load saved data
    local healData, analyticsHistory = Persistence.Load(DeficitHealer.charName)

    -- Initialize all modules
    Config.Load(DeficitHealer.charName)
    Logger.Init(DeficitHealer.charName, Config)
    Logger.Log('info', string.format(
        'init char=%s emergencyPct=%d minHealPct=%d overhealTol=%d groupHealMinCount=%d sustainedDps=%d',
        tostring(DeficitHealer.charName or ''),
        tonumber(Config.emergencyPct) or 0,
        tonumber(Config.minHealPct) or 0,
        tonumber(Config.overhealTolerancePct) or 0,
        tonumber(Config.groupHealMinCount) or 0,
        tonumber(Config.sustainedDamageThreshold) or 0
    ))
    if Logger.ShouldLog('debug') then
        local function list(spells)
            if not spells or #spells == 0 then return 'none' end
            return table.concat(spells, ',')
        end
        Logger.Log('debug', string.format(
            'spells fast=[%s] small=[%s] medium=[%s] large=[%s] group=[%s] hot=[%s] hotLight=[%s] groupHot=[%s] promised=[%s]',
            list(Config.spells.fast),
            list(Config.spells.small),
            list(Config.spells.medium),
            list(Config.spells.large),
            list(Config.spells.group),
            list(Config.spells.hot),
            list(Config.spells.hotLight),
            list(Config.spells.groupHot),
            list(Config.spells.promised)
        ))
    end
    HealTracker.Init(healData, Config.learningWeight)
    TargetMonitor.Init(Config)
    HealSelector.Init(Config, HealTracker)
    Proactive.Init(Config, HealTracker, TargetMonitor, HealSelector)
    CombatAssessor.Init(Config, TargetMonitor)
    Analytics.Init(analyticsHistory)  -- Pass saved history to restore it
    UI.Init(Config, HealTracker, TargetMonitor, HealSelector, Analytics)

    -- Log AA modifiers at startup
    local aaMods = HealTracker.GetAAModifiers()
    Logger.Log('info', string.format(
        'AA_MODIFIERS critPct=%.1f%% directHealBonus=%.1f%% hotBonus=%.1f%%',
        aaMods.critPct or 0,
        aaMods.directHealBonusPct or 0,
        aaMods.hotBonusPct or 0
    ))

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
    if Analytics.GetSessionStats then
        local stats = Analytics.GetSessionStats()
        if stats then
            Logger.Log('info', string.format(
                'shutdown duration=%ds casts=%d heals=%d efficiency=%.1f overheal=%.1f',
                tonumber(stats.duration) or 0,
                tonumber(stats.castsCount) or 0,
                tonumber(stats.healsCount) or 0,
                tonumber(stats.efficiency) or 0,
                tonumber(stats.overhealPct) or 0
            ))
        end
    end
    Logger.Shutdown()
end

function DeficitHealer.CastHeal(spellName, targetName, deficit, expected, source, details, targetInfo)
    if DeficitHealer.casting then return false end
    if mq.TLO.Me.Moving() then
        logSkip(targetInfo or { name = targetName, role = source }, 'moving', source)
        return false
    end
    if mq.TLO.Me.Stunned() then
        logSkip(targetInfo or { name = targetName, role = source }, 'stunned', source)
        return false
    end

    local spellInfo = mq.TLO.Spell(spellName)
    local subcategory = spellInfo and spellInfo() and normalizeText(spellInfo.Subcategory()) or ''
    local isHotSpell = subcategory == 'duration heals'
    local meta = getSpellMeta(spellName)
    Analytics.RecordCast(spellName, meta)

    if source then
        local detailText = details and details ~= '' and (' | ' .. details) or ''
        -- Include target HP info for debugging
        local hpInfo = ''
        if targetInfo then
            local defPct = (targetInfo.maxHP and targetInfo.maxHP > 0) and (deficit / targetInfo.maxHP * 100) or 0
            hpInfo = string.format(' [HP: %d/%d (%.1f%% missing)]',
                targetInfo.currentHP or 0, targetInfo.maxHP or 0, defPct)
        end
        local metaInfo = formatSpellMeta(meta)
        local summary = formatTargetInfo(targetInfo)
        if metaInfo ~= '' then
            metaInfo = ' ' .. metaInfo
        end
        if summary ~= '' then
            summary = ' ' .. summary
        end
        logDecision(string.format('Cast %s on %s expected=%s source=%s%s%s%s%s', spellName, targetName, expected or 0, source, summary, metaInfo, hpInfo, detailText))
    end

    -- Record reaction time if we have first noticed deficit for this target
    local noticed = firstNoticedDeficit[targetName]
    if noticed then
        local reactionMs = nowMs() - noticed.time
        Analytics.RecordReactionTime(noticed.deficitPct, reactionMs)
        firstNoticedDeficit[targetName] = nil
    end

    -- Track current cast for duck monitoring
    local isEmergency = source == 'emergency'

    -- Get initial HP% for duck logging and pre-cast guard
    local initialPct = 0
    local targetSpawn = mq.TLO.Spawn('pc ' .. targetName)
    if targetSpawn and targetSpawn() then
        initialPct = tonumber(targetSpawn.PctHPs()) or 0
    end
    local duckThreshold, effectiveThreshold, minDeficitPct, isSquishy, classShort, buffer = getDuckThreshold(
        targetName,
        targetSpawn,
        isHotSpell,
        isEmergency
    )

    if not isEmergency and initialPct > 0 and initialPct >= effectiveThreshold then
        logSkip(targetInfo or { name = targetName, role = source }, 'pre_duck_threshold', source)
        Logger.Log('debug', string.format(
            'PRE_DUCK spell=%s target=%s hp=%.1f%% duckAt=%.1f%% base=%d%% buffer=%.1f%% minDeficitPct=%.1f class=%s squishy=%s emergency=%s hot=%s',
            spellName, targetName, initialPct, effectiveThreshold, duckThreshold, buffer, minDeficitPct,
            tostring(classShort or ''), tostring(isSquishy), tostring(isEmergency), tostring(isHotSpell)
        ))
        return false
    end

    mq.cmdf('/target %s', targetName)
    mq.delay(100)
    mq.cmdf('/cast "%s"', spellName)

    DeficitHealer.casting = true

    -- Log cast start with duck threshold info
    local nearThreshold = initialPct >= (effectiveThreshold - 5)  -- Within 5% of duck threshold
    local overThreshold = initialPct >= effectiveThreshold
    local warningTag = ''
    if overThreshold then
        warningTag = ' [WARN: already over duck threshold!]'
    elseif nearThreshold then
        warningTag = ' [NOTE: near duck threshold]'
    end
    Logger.Log('debug', string.format(
        'CAST_START spell=%s target=%s hp=%.1f%% duckAt=%.1f%% base=%d%% buffer=%.1f%% minDeficitPct=%.1f class=%s squishy=%s emergency=%s hot=%s source=%s%s',
        spellName, targetName, initialPct, effectiveThreshold, duckThreshold, buffer, minDeficitPct, tostring(classShort or ''), tostring(isSquishy),
        tostring(isEmergency), tostring(isHotSpell), tostring(source), warningTag
    ))

    DeficitHealer.currentCast = {
        target = targetName,
        spell = spellName,
        isEmergency = isEmergency,
        isHot = isHotSpell,  -- Don't duck HoTs - they're low mana and meant for topping off
        startTime = nowMs(),
        initialPct = initialPct,
        duckThreshold = effectiveThreshold,
        minDeficitPct = minDeficitPct,
        isSquishy = isSquishy,
        classShort = classShort,
    }
    HealSelector.SetLastAction({
        spell = spellName,
        target = targetName,
        expected = expected or 0,
        time = os.time()
    })

    -- Store pending heal info for analytics when the heal event fires
    if isHotSpell then
        addPendingHot(spellName, targetName, deficit, expected)
        Proactive.RecordHot(targetName, spellName, getSpellDurationSec(spellName))
    else
        addPendingCast(spellName, targetName, deficit, expected)
    end

    return true
end

function DeficitHealer.ProcessHealing()
    -- Update target info
    TargetMonitor.Update()
    Proactive.Update()
    cleanupPending()

    -- Check casting state
    if mq.TLO.Me.Casting() then
        DeficitHealer.casting = true
        -- Track what we're casting for manual cast detection
        local castingName = mq.TLO.Me.Casting.Name()
        if castingName then
            lastCastSpell = castingName
            lastCastTimeMs = nowMs()
        end

        -- Check if we should duck the heal (target HP recovered)
        local shouldDuck, duckReason = shouldDuckHeal()
        if shouldDuck then
            duckSpell(duckReason)
            -- Don't return - continue processing to potentially start a new heal
        else
            return
        end
    else
        DeficitHealer.casting = false
        DeficitHealer.currentCast = nil  -- Clear cast tracking when not casting
    end

    -- Check if pendingGroupHeal is stale (> 2 seconds old) and finalize it
    if pendingGroupHeal and (nowMs() - pendingGroupHeal.startTimeMs) > pendingGroupHeal.windowMs then
        local totalActual = 0
        local totalFull = 0
        for _, h in ipairs(pendingGroupHeal.heals) do
            totalActual = totalActual + h.amount
            totalFull = totalFull + (h.full or h.amount)
        end
        Analytics.RecordHeal(pendingGroupHeal.spell, totalActual, totalFull, pendingGroupHeal.deficit, 'Group')
        local totalPotential = totalFull > 0 and totalFull or totalActual
        local overheal = math.max(0, totalPotential - totalActual)
        local eff = totalPotential > 0 and (totalActual / totalPotential) * 100 or 0
        Logger.Log('info', string.format(
            'GROUP_SUMMARY spell=%s totalActual=%d totalPotential=%d overheal=%d eff=%.1f targets=%d deficit=%d category=%s',
            tostring(pendingGroupHeal.spell or ''),
            totalActual,
            totalPotential,
            overheal,
            eff,
            (pendingGroupHeal.targets and (function(t)
                local count = 0
                for _ in pairs(t) do count = count + 1 end
                return count
            end)(pendingGroupHeal.targets)) or 0,
            tonumber(pendingGroupHeal.deficit) or 0,
            tostring(pendingGroupHeal.category or 'group')
        ))
        pendingGroupHeal = nil
    end

    local allTargets = TargetMonitor.GetAllTargets()
    local priorityTargets = TargetMonitor.GetPriorityTargets()
    local groupTargets = TargetMonitor.GetGroupTargets()
    applyIncomingHot(allTargets)
    applyIncomingHot(priorityTargets)
    applyIncomingHot(groupTargets)

    -- Track when we first notice each target with a deficit (for reaction time)
    for _, t in ipairs(allTargets) do
        if t.deficit > 0 and not firstNoticedDeficit[t.name] then
            firstNoticedDeficit[t.name] = {
                time = nowMs(),
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
    local mobs, mezzed, maPct, healers = getControlMetrics()
    situation.mobs = mobs or 0
    situation.mezzed = mezzed or 0
    situation.maPct = maPct
    situation.healers = healers or 0
    local activeMobs = math.max(0, (situation.mobs or 0) - (situation.mezzed or 0))
    situation.activeMobs = activeMobs
    local maxLowMobs = Config.lowPressureMobCount or 1
    situation.lowPressure = (not situation.hasEmergency) and (not situation.multipleHurt) and (activeMobs <= maxLowMobs)

    -- Combat assessment for fight duration and survival mode
    local tankInfo = priorityTargets[1] or allTargets[1]
    local combatAssessment = CombatAssessor.Assess(tankInfo)
    situation.combatAssessment = combatAssessment
    situation.survivalMode = combatAssessment and combatAssessment.survivalMode or false
    situation.fightPhase = combatAssessment and combatAssessment.fightPhase or 'none'
    situation.estimatedFightDuration = combatAssessment and combatAssessment.estimatedDurationSec or 0

    logTickSummary(allTargets, situation)
    logDpsValidation(allTargets)

    -- Priority 1: Emergency heals (anyone below threshold)
    for _, t in ipairs(allTargets) do
        if t.pctHP < Config.emergencyPct then
            local heal, reason = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name, t.deficit, heal.expected, 'emergency', heal.details, t)
                Analytics.RecordCriticalEvent(t.name, t.pctHP)
                return
            end
            logSkip(t, reason, 'emergency')
        end
    end

    -- Priority 2: Group heal check
    local useGroup, groupHeal = HealSelector.ShouldUseGroupHeal(allTargets)
    if useGroup and groupHeal then
        -- For group heals, estimate total deficit from all hurt targets
        local totalDeficit = 0
        local groupTargets = {}
        local targetDeficits = {}
        for _, t in ipairs(allTargets) do
            if t.deficit > 0 then
                totalDeficit = totalDeficit + t.deficit
                groupTargets[t.name] = true
                targetDeficits[t.name] = t.deficit
            end
        end

        recordReactionForTargets(groupTargets)
        Analytics.RecordCast(groupHeal.spell, getSpellMeta(groupHeal.spell))
        local groupDetails = groupHeal.details and (' | ' .. groupHeal.details) or ''
        logDecision(string.format('Cast %s on group (%d targets)%s', groupHeal.spell, groupHeal.targets or 0, groupDetails))

        -- Set up pendingGroupHeal instead of pendingCasts for group heals
        -- This allows accumulating multiple heal events from the group heal
        pendingGroupHeal = {
            spell = groupHeal.spell,
            deficit = totalDeficit,
            startTimeMs = nowMs(),
            windowMs = getSpellWindowMs(groupHeal.spell, GROUP_HEAL_WINDOW_MS),
            targets = groupTargets,
            targetDeficits = targetDeficits,
            expectedPerTarget = groupHeal.expected or 0,
            category = 'group',
            heals = {},
        }

        -- Cast the group heal (don't use DeficitHealer.CastHeal to avoid setting pendingCasts)
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

    -- Priority 2.5: Group HoT when stable
    if not situation.hasEmergency then
        local useGroupHot, groupHot, totalDeficit, hurtCount = Proactive.ShouldApplyGroupHot(allTargets, situation)
        if useGroupHot and groupHot then
            local groupTargets = {}
            local targetDeficits = {}
            for _, t in ipairs(allTargets) do
                if t.deficit > 0 then
                    groupTargets[t.name] = true
                    targetDeficits[t.name] = t.deficit
                end
            end

            recordReactionForTargets(groupTargets)
            Analytics.RecordCast(groupHot.spell, getSpellMeta(groupHot.spell))
            local groupHotDetails = groupHot.details and (' | ' .. groupHot.details) or ''
            logDecision(string.format('Cast %s on group (HoT)%s', groupHot.spell, groupHotDetails))

            pendingGroupHeal = {
                spell = groupHot.spell,
                deficit = totalDeficit or 0,
                startTimeMs = nowMs(),
                windowMs = getSpellWindowMs(groupHot.spell, GROUP_HEAL_WINDOW_MS),
                targets = groupTargets,
                targetDeficits = targetDeficits,
                expectedPerTarget = groupHot.expected or 0,
                category = 'groupHot',
                heals = {},
            }

            if not DeficitHealer.casting then
                mq.cmdf('/target %s', mq.TLO.Me.Name())
                mq.delay(100)
                mq.cmdf('/cast "%s"', groupHot.spell)

                DeficitHealer.casting = true
                HealSelector.SetLastAction({
                    spell = groupHot.spell,
                    target = mq.TLO.Me.Name(),
                    expected = 0,
                    time = os.time()
                })
            end
            return
        end
    end

    -- Priority 3: Priority targets (MT/MA)
    for _, t in ipairs(priorityTargets) do
        if t.deficit > 0 then
            local heal, reason = HealSelector.SelectHeal(t, situation)
            if heal then
                if heal.category == 'hot' and Proactive.HasActiveHot(t.name) then
                    local canRefresh = Proactive.ShouldRefreshHot and Proactive.ShouldRefreshHot(t.name, Config) or false
                    if not canRefresh then
                        -- Check class-based threshold before fallback to direct heal
                        local deficitPct = (t.maxHP and t.maxHP > 0) and (t.deficit / t.maxHP * 100) or 0
                        local fallbackMinPct = Config.minHealPct or 10
                        if not t.isSquishy and Config.nonSquishyMinHealPct then
                            fallbackMinPct = math.max(fallbackMinPct, Config.nonSquishyMinHealPct)
                        end
                        if deficitPct < fallbackMinPct then
                            reason = 'hot_active_fallback_below_min_pct'
                            heal = nil
                        else
                            local fallback = HealSelector.FindEfficientHeal(t, false, situation)
                            if not fallback then
                                reason = 'hot_active_no_fallback'
                            end
                            heal = fallback
                        end
                    end
                end
                if heal then
                    DeficitHealer.CastHeal(heal.spell, t.name, t.deficit, heal.expected, 'priority', heal.details, t)
                    return
                end
            end
            logSkip(t, reason, 'priority')
        end
    end

    -- Priority 4: Group members
    for _, t in ipairs(groupTargets) do
        if t.deficit > 0 then
            local heal, reason = HealSelector.SelectHeal(t, situation)
            if heal then
                if heal.category == 'hot' and Proactive.HasActiveHot(t.name) then
                    local canRefresh = Proactive.ShouldRefreshHot and Proactive.ShouldRefreshHot(t.name, Config) or false
                    if not canRefresh then
                        -- Check class-based threshold before fallback to direct heal
                        local deficitPct = (t.maxHP and t.maxHP > 0) and (t.deficit / t.maxHP * 100) or 0
                        local fallbackMinPct = Config.minHealPct or 10
                        if not t.isSquishy and Config.nonSquishyMinHealPct then
                            fallbackMinPct = math.max(fallbackMinPct, Config.nonSquishyMinHealPct)
                        end
                        if deficitPct < fallbackMinPct then
                            reason = 'hot_active_fallback_below_min_pct'
                            heal = nil
                        else
                            local fallback = HealSelector.FindEfficientHeal(t, false, situation)
                            if not fallback then
                                reason = 'hot_active_no_fallback'
                            end
                            heal = fallback
                        end
                    end
                end
                if heal then
                    DeficitHealer.CastHeal(heal.spell, t.name, t.deficit, heal.expected, 'group', heal.details, t)
                    return
                end
            end
            logSkip(t, reason, 'group')
        end
    end

    -- Priority 5: Proactive heals (HoTs/Promised when stable)
    if not situation.hasEmergency then
        for _, t in ipairs(priorityTargets) do
            local shouldHot, hotInfo, hotBlockReason = Proactive.ShouldApplyHot(t, situation)
            if shouldHot and hotInfo then
                -- Proactive heals don't have deficit context, pass 0
                DeficitHealer.CastHeal(hotInfo.spell, t.name, 0, 0, 'hot', hotInfo.details, t)
                Proactive.RecordHot(t.name, hotInfo.spell, getSpellDurationSec(hotInfo.spell))
                return
            elseif hotBlockReason then
                Logger.Log('debug', string.format('HOT_BLOCKED target=%s reason=%s', t.name or '', hotBlockReason))
            end

            local shouldPromised, promisedInfo, promisedBlockReason = Proactive.ShouldApplyPromised(t, situation)
            if shouldPromised and promisedInfo then
                -- Proactive heals don't have deficit context, pass 0
                DeficitHealer.CastHeal(promisedInfo.spell, t.name, 0, 0, 'promised', promisedInfo.details, t)
                local promisedDelay = Config.promisedDelaySeconds or 18
                local promisedExpected = promisedInfo.expected or 0
                Proactive.RecordPromised(t.name, promisedInfo.spell, getSpellDurationSec(promisedInfo.spell), promisedExpected, promisedDelay)
                return
            elseif promisedBlockReason then
                Logger.Log('debug', string.format('PROMISED_BLOCKED target=%s reason=%s', t.name or '', promisedBlockReason))
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

    if UI.ConsumeShutdownRequested and UI.ConsumeShutdownRequested() then
        DeficitHealer.Shutdown()
    end
end

DeficitHealer.Shutdown()
