-- proactive.lua
local mq = require('mq')
local CombatAssessor = require('deficithealer.combatassessor')

local Proactive = {
    config = nil,
    healTracker = nil,
    targetMonitor = nil,
    healSelector = nil,
    activeHots = {},      -- targetName -> { spell, expireTime }
    activePromised = {},  -- targetName -> { spell, expireTime }
    lastHotLearnAttempt = {}, -- targetName -> last attempt time (os.time)
}

function Proactive.Init(config, healTracker, targetMonitor, healSelector)
    Proactive.config = config
    Proactive.healTracker = healTracker
    Proactive.targetMonitor = targetMonitor
    Proactive.healSelector = healSelector
end

function Proactive.Update()
    local now = os.time()

    -- Clean up expired HoTs
    for name, data in pairs(Proactive.activeHots) do
        if data.expireTime < now then
            Proactive.activeHots[name] = nil
        end
    end

    -- Clean up expired Promised
    for name, data in pairs(Proactive.activePromised) do
        if data.expireTime < now then
            Proactive.activePromised[name] = nil
        end
    end
end

function Proactive.RecordHot(targetName, spellName, duration)
    local now = os.time()
    Proactive.activeHots[targetName] = {
        spell = spellName,
        castTime = now,
        duration = duration,
        expireTime = now + duration,
    }
end

function Proactive.RecordPromised(targetName, spellName, duration, expectedHeal, delaySeconds)
    local now = os.time()
    local delay = delaySeconds or 18  -- Default Promised delay
    Proactive.activePromised[targetName] = {
        spell = spellName,
        castTime = now,
        delay = delay,
        landingTime = now + delay,
        expireTime = now + duration,
        expectedHeal = expectedHeal or 0,
    }
end

-- Get Promised landing info for a target
-- Returns: { timeRemaining, expectedHeal, spell } or nil
function Proactive.GetPromisedLandingInfo(targetName)
    local data = Proactive.activePromised[targetName]
    if not data then
        return nil
    end

    local now = os.time()

    -- If already landed (past landing time but not expired), return nil
    if now >= data.landingTime then
        return nil
    end

    local timeRemaining = data.landingTime - now
    return {
        timeRemaining = timeRemaining,
        expectedHeal = data.expectedHeal or 0,
        spell = data.spell,
        landingTime = data.landingTime,
    }
end

-- Get expected HoT healing within a time window
-- Returns total expected healing from active HoT ticks in the window
function Proactive.GetHotHealingInWindow(targetName, windowSec)
    local data = Proactive.activeHots[targetName]
    if not data then
        return 0
    end

    local tracker = Proactive.healTracker
    if not tracker then
        return 0
    end

    -- Get expected HP per tick from HealTracker
    local hpPerTick = tracker.GetExpectedHeal(data.spell) or 0
    if hpPerTick <= 0 then
        return 0
    end

    local now = os.time()
    local elapsed = now - (data.castTime or now)
    local remaining = math.max(0, (data.duration or 0) - elapsed)

    -- Calculate ticks in the window (6 second tick interval)
    local tickInterval = 6
    local windowRemaining = math.min(windowSec, remaining)
    local ticksInWindow = math.floor(windowRemaining / tickInterval)

    return ticksInWindow * hpPerTick
end

-- Calculate projected HP considering HoT + Promised + incoming DPS
-- Returns: { projectedHP, projectedPct, details }
function Proactive.CalculateProjectedHP(targetInfo, promisedInfo)
    if not promisedInfo or not promisedInfo.timeRemaining then
        return nil
    end

    local config = Proactive.config
    local windowSec = promisedInfo.timeRemaining
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local dps = targetInfo.recentDps or 0

    -- Expected damage during wait
    local expectedDamage = dps * windowSec

    -- Expected HoT healing during wait
    local hotHealing = Proactive.GetHotHealingInWindow(targetInfo.name, windowSec)

    -- Promised heal amount
    local promisedHealing = promisedInfo.expectedHeal or 0

    -- Calculate projected HP when Promised lands
    local projectedHP = currentHP - expectedDamage + hotHealing + promisedHealing
    projectedHP = math.min(projectedHP, maxHP)  -- Cap at max HP
    projectedHP = math.max(projectedHP, 0)      -- Floor at 0

    local projectedPct = (projectedHP / maxHP) * 100

    local details = string.format(
        'projHP=%.0f projPct=%.1f curHP=%.0f dmg=%.0f hotHeal=%.0f promHeal=%.0f window=%ds',
        projectedHP, projectedPct, currentHP, expectedDamage, hotHealing, promisedHealing, windowSec
    )

    return {
        projectedHP = projectedHP,
        projectedPct = projectedPct,
        expectedDamage = expectedDamage,
        hotHealing = hotHealing,
        promisedHealing = promisedHealing,
        windowSec = windowSec,
        details = details,
    }
end

-- Check if it's safe to wait for Promised (skip direct heals)
-- Returns: isSafe, projection details
function Proactive.IsSafeToWaitForPromised(targetInfo)
    local config = Proactive.config
    if not config then
        return false, nil
    end

    local promisedInfo = Proactive.GetPromisedLandingInfo(targetInfo.name)
    if not promisedInfo then
        return false, nil
    end

    local projection = Proactive.CalculateProjectedHP(targetInfo, promisedInfo)
    if not projection then
        return false, nil
    end

    -- Safety floor - use dynamic floor that increases in survival mode
    -- In survival mode (high DPS), we need a higher floor since damage can spike
    local safetyFloorPct = CombatAssessor.GetPromisedSafetyFloor and CombatAssessor.GetPromisedSafetyFloor()
        or (config.promisedSafetyFloorPct or 35)

    -- Also check the minimum HP during the wait (before Promised lands)
    -- This is: currentHP - expectedDamage + hotHealing (without Promised)
    local minHPDuringWait = (targetInfo.currentHP or 0) - projection.expectedDamage + projection.hotHealing
    local minPctDuringWait = ((targetInfo.maxHP or 1) > 0) and (minHPDuringWait / targetInfo.maxHP * 100) or 0

    -- Check if we stay above safety floor throughout the wait
    local isSafe = minPctDuringWait >= safetyFloorPct

    projection.minHPDuringWait = minHPDuringWait
    projection.minPctDuringWait = minPctDuringWait
    projection.safetyFloorPct = safetyFloorPct
    projection.isSafe = isSafe
    projection.details = projection.details .. string.format(
        ' minPct=%.1f safetyFloor=%d%% safe=%s timeToLand=%ds',
        minPctDuringWait, safetyFloorPct, tostring(isSafe), promisedInfo.timeRemaining or 0
    )

    return isSafe, projection
end

function Proactive.HasActiveHot(targetName)
    local data = Proactive.activeHots[targetName]
    return data and data.expireTime > os.time()
end

function Proactive.GetHotRemainingPct(targetName)
    local data = Proactive.activeHots[targetName]
    if not data or not data.duration or data.duration <= 0 then
        return 0
    end
    local now = os.time()
    local elapsed = now - (data.castTime or now)
    local remaining = math.max(0, data.duration - elapsed)
    return (remaining / data.duration) * 100
end

function Proactive.ShouldRefreshHot(targetName, config)
    local remainingPct = Proactive.GetHotRemainingPct(targetName)
    local refreshWindow = config and config.hotRefreshWindowPct or 25
    return remainingPct > 0 and remainingPct < refreshWindow
end

function Proactive.HasActivePromised(targetName)
    local data = Proactive.activePromised[targetName]
    return data and data.expireTime > os.time()
end

function Proactive.ShouldApplyHot(targetInfo, situation)
    local config = Proactive.config
    local monitor = Proactive.targetMonitor
    local selector = Proactive.healSelector
    local tracker = Proactive.healTracker
    local nonSquishy = not targetInfo.isSquishy

    if config and config.hotEnabled == false then
        return false, nil
    end

    -- Don't apply if already has HoT unless refreshing
    if Proactive.HasActiveHot(targetInfo.name) and not Proactive.ShouldRefreshHot(targetInfo.name, config) then
        return false, nil
    end

    -- Don't apply if no deficit
    if targetInfo.deficit <= 0 then
        return false, nil
    end

    -- Role-based HoT restriction: Long HoTs are only efficient on tanks (MT/MA)
    -- Non-tanks only get HoTs if they have sustained incoming damage
    local isPriorityTarget = targetInfo.role == 'MT' or targetInfo.role == 'MA'
    local isHighPressure = monitor and monitor.IsHighPressure and monitor.IsHighPressure(config) or false

    -- Prefer HoTs when incoming DPS is low, unless high pressure on tanks
    local dps = monitor.GetCombinedDPS and monitor.GetCombinedDPS(targetInfo.name, config.damageWindowSec)
        or monitor.GetRecentDPS(targetInfo.name, config.damageWindowSec)
    local hotPreferUnderDps = config.hotPreferUnderDps or config.sustainedDamageThreshold or 3000
    if dps > hotPreferUnderDps and not (isPriorityTarget and isHighPressure) then
        return false, nil
    end

    -- Non-tanks only get HoTs if they have sustained incoming damage
    local hotMinDpsForNonTank = config.hotMinDpsForNonTank or 500
    if not isPriorityTarget and dps < hotMinDpsForNonTank then
        return false, nil
    end

    local learning = tracker and tracker.IsLearning and tracker.IsLearning()
    local allowLearn = learning and config.hotLearnForce
    local deficitPct = targetInfo.maxHP > 0 and (targetInfo.deficit / targetInfo.maxHP) * 100 or 0
    local hotMaxPct = config.hotMaxDeficitPct or 25
    local learnMaxPct = config.hotLearnMaxDeficitPct or hotMaxPct
    if nonSquishy and config.nonSquishyHotMinDeficitPct and deficitPct < config.nonSquishyHotMinDeficitPct then
        return false, nil
    end
    local hotMinDeficitPct = config.hotMinDeficitPct or 5
    if deficitPct < hotMinDeficitPct and not (config.hotLearnForce and deficitPct <= learnMaxPct) then
        return false, nil
    end

    if deficitPct > hotMaxPct and not allowLearn then
        return false, nil
    end
    if allowLearn and deficitPct > learnMaxPct then
        return false, nil
    end

    if allowLearn then
        local lastAttempt = Proactive.lastHotLearnAttempt[targetInfo.name] or 0
        local intervalSec = config.hotLearnIntervalSec or 30
        if (os.time() - lastAttempt) < intervalSec then
            return false, nil
        end
    end

    -- Non-tanks ALWAYS get hotLight; tanks get big HoT only in high-pressure
    local useLight = true  -- Default to light for everyone
    if isPriorityTarget and isHighPressure then
        useLight = false  -- Only tanks in high-pressure get big HoT
    end

    -- Select the HoT spell first, then check combat assessment with actual duration
    local best = nil
    if selector and selector.SelectBestHot then
        best = selector.SelectBestHot(targetInfo, useLight)
    else
        -- Fallback: use hotLight by default, hot only in high pressure
        local hotList = config.spells.hotLight
        if not useLight or not hotList or #hotList == 0 then
            hotList = config.spells.hot
        end
        if hotList and #hotList > 0 then
            best = { spell = hotList[1] }
        end
    end

    if not best then
        return false, nil
    end

    -- Check combat assessment with actual spell duration (not config default)
    -- This allows short HoTs in survival mode while blocking long ones
    local assessment = situation and situation.combatAssessment
    if assessment then
        local actualDuration = best.duration or config.hotTypicalDuration or 36
        local allowed, reason = CombatAssessor.ShouldAllowHot(assessment, actualDuration)
        if not allowed then
            return false, nil, reason  -- Return reason for logging
        end
    end

    -- Add details
    if allowLearn then
        Proactive.lastHotLearnAttempt[targetInfo.name] = os.time()
        if best.details then
            best.details = best.details .. ' | trigger=hot_learn_force'
        else
            best.details = 'trigger=hot_learn_force'
        end
    end
    if useLight then
        best.details = (best.details or '') .. ' lightHot=true'
    else
        best.details = (best.details or '') .. ' bigHot=true highPressure=true'
    end
    return true, best
end

function Proactive.ShouldApplyGroupHot(targets, situation)
    local config = Proactive.config
    local selector = Proactive.healSelector
    if config and config.hotEnabled == false then
        return false, nil, nil, nil
    end

    if situation.hasEmergency then
        return false, nil, nil, nil
    end

    local hurtCount = 0
    local totalDeficit = 0
    for _, t in ipairs(targets) do
        if t.deficit > 0 then
            hurtCount = hurtCount + 1
            totalDeficit = totalDeficit + t.deficit
        end
    end

    if hurtCount < (config.groupHealMinCount or 2) then
        return false, nil, nil, nil
    end

    if selector and selector.SelectBestGroupHot then
        local best = selector.SelectBestGroupHot(targets, totalDeficit, hurtCount)
        if best then
            return true, best, totalDeficit, best.targets or hurtCount
        end
    end

    return false, nil, nil, nil
end

function Proactive.ShouldApplyPromised(targetInfo, situation)
    local config = Proactive.config
    local selector = Proactive.healSelector

    -- Check if Promised heals are enabled
    if config and config.promisedEnabled == false then
        return false, nil
    end

    -- Only for tanks (priority targets)
    if targetInfo.role ~= 'MT' and targetInfo.role ~= 'MA' then
        return false, nil
    end

    -- Check combat assessment - don't use Promised if fight is ending or tank below floor
    local assessment = situation and situation.combatAssessment
    if assessment then
        local allowed, reason = CombatAssessor.ShouldAllowPromised(assessment, targetInfo.pctHP)
        if not allowed then
            return false, nil, reason  -- Return reason for logging
        end
    end

    -- Check if there's already a Promised pending (hasn't landed yet)
    local pendingPromised = Proactive.GetPromisedLandingInfo(targetInfo.name)
    if pendingPromised then
        -- Promised is still pending, don't cast another
        return false, nil
    end

    -- If rolling is enabled, we cast when previous has landed
    -- If not rolling, only cast if no active Promised at all
    local rolling = config and config.promisedRolling ~= false
    if not rolling and Proactive.HasActivePromised(targetInfo.name) then
        return false, nil
    end

    -- Only apply when stable (no emergency)
    if situation.hasEmergency then
        return false, nil
    end

    -- Only apply when tank is reasonably healthy
    -- With rolling Promised, we can be more aggressive since we expect coverage
    local minHpPct = rolling and 40 or 50
    if targetInfo.pctHP < minHpPct then
        return false, nil
    end

    -- For rolling, require some incoming damage (combat situation)
    if rolling and (targetInfo.recentDps or 0) < 100 then
        return false, nil
    end

    -- Find appropriate Promised heal
    if selector and selector.SelectBestPromised then
        local best = selector.SelectBestPromised(targetInfo)
        if best then
            return true, best
        end
    else
        for _, spellName in ipairs(config.spells.promised or {}) do
            return true, { spell = spellName }
        end
    end

    return false, nil
end

function Proactive.GetActiveBuffs(targetName)
    return {
        hot = Proactive.activeHots[targetName],
        promised = Proactive.activePromised[targetName],
    }
end

return Proactive
