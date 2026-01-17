-- healselector.lua
local mq = require('mq')
local TargetMonitor = require('deficithealer.targetmonitor')
local Proactive = require('deficithealer.proactive')

local HealSelector = {
    config = nil,
    healTracker = nil,
    lastAction = nil,
}

local TICK_MS = 6000

function HealSelector.Init(config, healTracker)
    HealSelector.config = config
    HealSelector.healTracker = healTracker
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

local function isSpellUsable(spellName, meta)
    local ready = mq.TLO.Me.SpellReady(spellName)
    if ready ~= nil and not ready() then
        return false
    end
    local currentMana = mq.TLO.Me.CurrentMana() or 0
    if meta.mana > 0 and currentMana < meta.mana then
        return false
    end
    return true
end

local function predictedDeficit(deficit, dps, timeSec, maxHP)
    if not dps or dps <= 0 or not timeSec or timeSec <= 0 then
        return deficit
    end
    local predicted = deficit + (dps * timeSec)
    if maxHP and predicted > maxHP then
        predicted = maxHP
    end
    return predicted
end

local function getSingleWeights(config, situation)
    local defaults = { coverage = 3.0, manaEff = 0.5, overheal = -1.5 }
    local presets = config and config.scoringPresets or nil
    local weights = (presets and presets.normal) or defaults
    -- Survival mode or emergency both use emergency weights (prioritize speed over efficiency)
    if situation and (situation.hasEmergency or situation.survivalMode) and presets and presets.emergency then
        weights = presets.emergency
    elseif situation and situation.lowPressure and presets and presets.lowPressure then
        weights = presets.lowPressure
    end
    return {
        coverage = tonumber(weights.coverage) or defaults.coverage,
        manaEff = tonumber(weights.manaEff) or defaults.manaEff,
        overheal = tonumber(weights.overheal) or defaults.overheal,
    }
end

local function formatSingleWeights(weights)
    return string.format('weights=cov%.1f,mana%.1f,overheal%.1f,cast-0.2,recast-0.1',
        weights.coverage, weights.manaEff, weights.overheal)
end

local function scoreSingle(meta, expected, deficit, dps, maxHP, situation, targetInfo)
    local config = HealSelector.config
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local adjustedDps = dps
    local burst = false
    if TargetMonitor and targetInfo and targetInfo.name and TargetMonitor.IsBurstDamage then
        local burstThreshold = config and config.burstStddevMultiplier or 1.5
        burst = TargetMonitor.IsBurstDamage(targetInfo.name, burstThreshold, config and config.damageWindowSec)
        if burst then
            local scale = config and config.burstDpsScale or 1.5
            adjustedDps = dps * scale
        end
    end
    local predicted = predictedDeficit(deficit, adjustedDps, castSec, maxHP)
    local safeDeficit = math.max(predicted, 1)
    local coverage = math.min(expected, safeDeficit) / safeDeficit
    local overheal = math.max(0, expected - safeDeficit) / safeDeficit
    local manaEff = expected / mana
    local weights = getSingleWeights(config, situation)
    local score = (coverage * weights.coverage)
        + (manaEff * weights.manaEff)
        + (overheal * weights.overheal)
        - (castSec * 0.2)
        - (recastSec * 0.1)
    return score, {
        coverage = coverage,
        overheal = overheal,
        manaEff = manaEff,
        castSec = castSec,
        recastSec = recastSec,
        predicted = predicted,
        expected = expected,
        burst = burst,
        adjustedDps = adjustedDps,
    }, formatSingleWeights(weights)
end

local function scoreGroup(meta, expectedPerTarget, totalDeficit, hurtCount)
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local totalExpected = expectedPerTarget * hurtCount
    local safeDeficit = math.max(totalDeficit, 1)
    local coverage = math.min(totalExpected, safeDeficit) / safeDeficit
    local overheal = math.max(0, totalExpected - safeDeficit) / safeDeficit
    local manaEff = totalExpected / mana
    local score = (coverage * 3) + (manaEff * 0.5) - (overheal * 1.5) - (castSec * 0.2) - (recastSec * 0.1)
    return score, {
        coverage = coverage,
        overheal = overheal,
        manaEff = manaEff,
        castSec = castSec,
        recastSec = recastSec,
        expected = totalExpected,
        predicted = safeDeficit,
        targets = hurtCount,
    }
end

local function scoreHot(meta, expectedTick, deficit, dps, maxHP)
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local durationSec = math.max(meta.durationTicks * (TICK_MS / 1000), 1)
    local totalExpected = expectedTick * math.max(meta.durationTicks, 1)
    local predicted = predictedDeficit(deficit, dps, durationSec, maxHP)
    local safeDeficit = math.max(predicted, 1)
    local coverage = math.min(totalExpected, safeDeficit) / safeDeficit
    local manaEff = totalExpected / mana
    local hps = totalExpected / durationSec
    local score = (coverage * 2) + (manaEff * 0.5) + (hps * 0.001) - (castSec * 0.2) - (recastSec * 0.1)
    return score, {
        coverage = coverage,
        manaEff = manaEff,
        hps = hps,
        castSec = castSec,
        recastSec = recastSec,
        durationSec = durationSec,
        expected = totalExpected,
        predicted = safeDeficit,
    }
end

local function scorePromised(meta, expected, deficit, dps, maxHP)
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local delaySec = meta.durationTicks * (TICK_MS / 1000)
    local predicted = predictedDeficit(deficit, dps, delaySec, maxHP)
    local safeDeficit = math.max(predicted, 1)
    local coverage = math.min(expected, safeDeficit) / safeDeficit
    local manaEff = expected / mana
    local score = (coverage * 2) + (manaEff * 0.5) - (delaySec * 0.05) - (castSec * 0.2) - (recastSec * 0.1)
    return score, {
        coverage = coverage,
        manaEff = manaEff,
        delaySec = delaySec,
        castSec = castSec,
        recastSec = recastSec,
        expected = expected,
        predicted = safeDeficit,
    }
end

local function getExpectedWithFallback(tracker, spellName, fallback)
    local expected = tracker.GetExpectedHeal(spellName)
    if expected ~= nil then
        return expected
    end
    if tracker.IsLearning() and fallback and fallback > 0 then
        return fallback
    end
    return nil
end

local function attachExpected(allSpells, deficit, tracker)
    local list = {}
    for _, spell in ipairs(allSpells) do
        local expected = getExpectedWithFallback(tracker, spell.name, deficit)
        if expected then
            table.insert(list, { name = spell.name, cat = spell.cat, expected = expected })
        end
    end
    return list
end

local function preFilterSpells(allSpells, deficit, situation, tracker, config)
    local candidates = attachExpected(allSpells, deficit, tracker)
    if deficit <= 0 or #candidates == 0 then
        return candidates
    end

    local minCoverage = deficit * 0.5
    local maxOverheal = deficit * (config.maxOverhealRatio or 2.0)
    local filtered = {}
    for _, spell in ipairs(candidates) do
        local expected = spell.expected or 0
        if expected >= minCoverage then
            if expected <= maxOverheal or (situation and situation.hasEmergency) then
                table.insert(filtered, spell)
            end
        end
    end

    if #filtered == 0 then
        filtered = candidates
    end

    table.sort(filtered, function(a, b)
        return (a.expected or 0) < (b.expected or 0)
    end)

    return filtered
end

local function findUnderhealCandidate(candidates, deficit, tracker, config)
    if not candidates or #candidates == 0 or deficit <= 0 then
        return nil
    end
    local minPct = (config and config.underhealMinCoveragePct) or 80
    local minExpected = deficit * (minPct / 100)
    local best = nil
    for _, spell in ipairs(candidates) do
        local expected = spell.expected or getExpectedWithFallback(tracker, spell.name, deficit)
        if expected and expected < deficit and expected >= minExpected then
            if not best or expected > best.expected then
                best = {
                    spell = spell.name,
                    expected = expected,
                    category = spell.cat,
                    details = formatScoreDetails('underheal_prefer', 'single', nil, {
                        predicted = deficit,
                        expected = expected,
                    }),
                }
            end
        end
    end
    return best
end

-- Calculate how much direct healing is needed to supplement an active HoT
-- Returns: needsSupplement (bool), gap (HP needed), details (string)
local function calculateSupplementGap(targetInfo, config)
    if not Proactive or not Proactive.HasActiveHot or not Proactive.HasActiveHot(targetInfo.name) then
        -- No active HoT, full deficit needs healing
        return true, targetInfo.deficit, 'no_hot'
    end

    local hotData = Proactive.activeHots and Proactive.activeHots[targetInfo.name]
    if not hotData then
        return true, targetInfo.deficit, 'no_hot_data'
    end

    -- Get HoT parameters
    local remainingPct = Proactive.GetHotRemainingPct(targetInfo.name) or 0
    local duration = hotData.duration or 0
    local remainingSec = (remainingPct / 100) * duration

    -- Estimate HP per tick from HealTracker
    local tracker = HealSelector.healTracker
    local hpPerTick = 0
    if tracker and hotData.spell then
        hpPerTick = tracker.GetExpectedHeal(hotData.spell) or 0
    end
    if hpPerTick <= 0 then
        -- No data, assume HoT won't help
        return true, targetInfo.deficit, 'no_hot_data'
    end

    local tickInterval = TICK_MS / 1000  -- 6 seconds
    local ticksRemaining = math.floor(remainingSec / tickInterval)
    local remainingHotHealing = hpPerTick * ticksRemaining

    -- Calculate expected damage during remaining HoT duration
    local dps = targetInfo.recentDps or 0
    local minDpsForSupplement = (config and config.hotSupplementMinDps) or (config and config.hotMinDps) or 0
    if dps <= minDpsForSupplement then
        local details = string.format('hotRemain=%.0f dps=%.0f expDmg=0 net=%.0f gap=%.0f supplementBlocked=true',
            remainingHotHealing, dps, remainingHotHealing, targetInfo.deficit - remainingHotHealing)
        return false, 0, details
    end
    local expectedDamage = dps * remainingSec

    -- Net healing from HoT (healing minus expected damage)
    local netHotHealing = remainingHotHealing - expectedDamage

    -- Gap = deficit that HoT won't cover
    local gap = targetInfo.deficit - netHotHealing

    local details = string.format('hotRemain=%.0f dps=%.0f expDmg=%.0f net=%.0f gap=%.0f',
        remainingHotHealing, dps, expectedDamage, netHotHealing, gap)

    if gap <= 0 then
        -- HoT will cover it, no supplement needed
        return false, 0, details
    end

    return true, gap, details
end

local function joinDetails(primary, extra)
    if extra == nil or extra == '' then
        return primary
    end
    if primary == nil or primary == '' then
        return extra
    end
    return primary .. ' | ' .. extra
end

local function formatComponents(components)
    if not components then
        return ''
    end
    local parts = {}
    if components.coverage then
        table.insert(parts, string.format('cov=%.2f', components.coverage))
    end
    if components.overheal then
        table.insert(parts, string.format('oh=%.2f', components.overheal))
    end
    if components.manaEff then
        table.insert(parts, string.format('mana=%.2f', components.manaEff))
    end
    if components.hps then
        table.insert(parts, string.format('hps=%.1f', components.hps))
    end
    if components.delaySec then
        table.insert(parts, string.format('delay=%.1f', components.delaySec))
    end
    if components.castSec then
        table.insert(parts, string.format('cast=%.2f', components.castSec))
    end
    if components.recastSec then
        table.insert(parts, string.format('recast=%.2f', components.recastSec))
    end
    if components.durationSec then
        table.insert(parts, string.format('dur=%.1f', components.durationSec))
    end
    if components.predicted then
        table.insert(parts, string.format('pred=%.0f', components.predicted))
    end
    if components.adjustedDps then
        table.insert(parts, string.format('dpsAdj=%.0f', components.adjustedDps))
    end
    if components.burst ~= nil then
        table.insert(parts, string.format('burst=%s', tostring(components.burst)))
    end
    if components.expected then
        table.insert(parts, string.format('exp=%.0f', components.expected))
    end
    if components.targets then
        table.insert(parts, string.format('targets=%d', components.targets))
    end
    if #parts == 0 then
        return ''
    end
    return ' ' .. table.concat(parts, ' ')
end

local function formatScoreDetails(reason, model, score, components, weightsOverride)
    local weightMap = {
        single = 'weights=cov3,mana0.5,overheal-1.5,cast-0.2,recast-0.1',
        group = 'weights=cov3,mana0.5,overheal-1.5,cast-0.2,recast-0.1',
        hot = 'weights=cov2,mana0.5,hps0.001,cast-0.2,recast-0.1',
        groupHot = 'weights=cov3,mana0.5,overheal-1.5,cast-0.2,recast-0.1',
        promised = 'weights=cov2,mana0.5,delay-0.05,cast-0.2,recast-0.1',
    }
    local weights = weightsOverride or weightMap[model]
    if weights then
        weights = ' ' .. weights
    else
        weights = ''
    end
    local componentsText = formatComponents(components)
    if score then
        return string.format('reason=%s model=%s score=%.2f%s%s', reason, model, score, componentsText, weights)
    end
    return string.format('reason=%s model=%s%s%s', reason, model, componentsText, weights)
end

-- Find best heal for a given target and deficit
function HealSelector.SelectHeal(targetInfo, situation)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local deficit = targetInfo.deficit
    local learning = tracker and tracker.IsLearning and tracker.IsLearning()
    local nonSquishy = not targetInfo.isSquishy
    local lowPressure = situation and situation.lowPressure

    if deficit <= 0 then return nil, 'no_deficit' end

    -- Emergency: anyone below threshold gets fastest heal
    if targetInfo.pctHP < config.emergencyPct then
        local heal = HealSelector.FindFastestHeal(deficit)
        if heal then
            heal.details = joinDetails(heal.details, 'trigger=emergency')
        end
        if not heal then
            return nil, 'emergency_no_heal'
        end
        return heal
    end

    local deficitPct = (targetInfo.maxHP > 0) and (deficit / targetInfo.maxHP) * 100 or 0

    -- Check if Promised heal is pending and safe to wait for it
    -- This allows the tank to drop lower knowing the Promised will cover them
    if Proactive and Proactive.IsSafeToWaitForPromised then
        local isSafe, projection = Proactive.IsSafeToWaitForPromised(targetInfo)
        if isSafe and projection then
            local reason = 'promised_covering|' .. (projection.details or '')
            return nil, reason
        end
    end

    if config.considerIncomingHot and targetInfo.incomingHotRemaining and targetInfo.incomingHotRemaining > 0
        and targetInfo.recentDps <= config.sustainedDamageThreshold then
        local coveragePct = config.hotIncomingCoveragePct or 100
        local incoming = targetInfo.incomingHotRemaining or 0
        if deficit > 0 and incoming >= (deficit * (coveragePct / 100)) then
            return nil, 'incoming_hot_cover'
        end
        deficit = math.max(0, deficit - incoming)
        if deficit <= 0 then
            return nil, 'incoming_hot_cover'
        end
        deficitPct = (targetInfo.maxHP > 0) and (deficit / targetInfo.maxHP) * 100 or 0
    end

    -- HoT check FIRST - HoTs are efficient and can be used at higher HP if taking damage
    -- But only if there's actual damage happening OR meaningful deficit to heal
    -- IMPORTANT: Long-duration HoTs (36s) are only efficient on tanks taking sustained damage.
    -- For non-tanks with side damage, direct heals are almost always more mana-efficient.
    local hotEnabled = config.hotEnabled ~= false
    local hotMaxPct = config.hotMaxDeficitPct or 25
    local learnMaxPct = config.hotLearnMaxDeficitPct or hotMaxPct
    local hotPreferUnderDps = config.hotPreferUnderDps or config.sustainedDamageThreshold or 3000
    local hotMinDeficitPct = config.hotMinDeficitPct or 5
    if nonSquishy and config.nonSquishyHotMinDeficitPct then
        hotMinDeficitPct = math.max(hotMinDeficitPct, config.nonSquishyHotMinDeficitPct)
    end
    if lowPressure and nonSquishy and config.lowPressureHotMinDeficitPct then
        hotMinDeficitPct = math.max(hotMinDeficitPct, config.lowPressureHotMinDeficitPct)
    end
    local allowLearnHot = learning and config.hotLearnForce and deficitPct <= learnMaxPct
    local refreshable = true
    if Proactive and Proactive.HasActiveHot and Proactive.HasActiveHot(targetInfo.name) then
        refreshable = Proactive.ShouldRefreshHot and Proactive.ShouldRefreshHot(targetInfo.name, config) or false
    end

    -- Role-based HoT restriction: Long HoTs are only efficient on tanks (MT/MA)
    -- Non-tanks only get HoTs if they have sustained incoming damage that justifies it
    local isPriorityTarget = targetInfo.role == 'MT' or targetInfo.role == 'MA'
    local hotMinDpsForNonTank = config.hotMinDpsForNonTank or 500  -- Non-tanks need sustained DPS to justify HoT
    local hasSustainedDamage = (targetInfo.recentDps or 0) >= hotMinDpsForNonTank
    local isHighPressure, pressureReason, pressureValue = TargetMonitor.IsHighPressure(config)
    local allowHighPressureHot = isPriorityTarget and isHighPressure

    local hotEligible = hotEnabled
        and deficitPct >= hotMinDeficitPct
        and (deficitPct <= hotMaxPct or allowLearnHot)
        and ((targetInfo.recentDps or 0) <= hotPreferUnderDps or allowLearnHot or allowHighPressureHot)
        and refreshable
        and (isPriorityTarget or hasSustainedDamage or allowLearnHot)  -- Only tanks or sustained damage targets

    if hotEligible then
        -- Non-tanks ALWAYS get hotLight (more mana efficient, less waste)
        -- Tanks get big HoT only in high-pressure situations (>3 mobs or high DPS)
        local useLight = true  -- Default to light for everyone
        if isPriorityTarget and isHighPressure then
            useLight = false  -- Only tanks in high-pressure get big HoT
        end
        local bestHot = HealSelector.SelectBestHot(targetInfo, useLight)
        if bestHot then
            local trigger = allowLearnHot and 'trigger=hot_learn_force' or 'trigger=hot_preference'
            local refreshTag = (refreshable and Proactive and Proactive.HasActiveHot
                and Proactive.HasActiveHot(targetInfo.name)) and ' refresh=true' or ''
            local pressureTag = ''
            if not useLight then
                pressureTag = string.format(' bigHot=true highPressure=%s:%s', pressureReason or 'true', tostring(pressureValue or ''))
            else
                pressureTag = ' lightHot=true'
            end
            local detail = joinDetails(
                bestHot.details,
                string.format('%s dps=%.0f deficitPct=%.1f%s%s', trigger, targetInfo.recentDps or 0, deficitPct, refreshTag, pressureTag)
            )
            return { spell = bestHot.spell, expected = bestHot.expected, category = 'hot', details = detail }
        end
    end

    -- SUPPLEMENT LOGIC: If target has active HoT, check if it's keeping up or needs supplementing
    -- This is the key to the "HoT as baseline, direct heal as supplement" philosophy
    if Proactive and Proactive.HasActiveHot and Proactive.HasActiveHot(targetInfo.name) then
        -- Check class-based min threshold BEFORE considering supplement
        -- Non-squishies at high HP shouldn't get supplements either
        local supplementMinPct = config.minHealPct or 10
        if nonSquishy and config.nonSquishyMinHealPct then
            supplementMinPct = math.max(supplementMinPct, config.nonSquishyMinHealPct)
        end
        if lowPressure and nonSquishy and config.lowPressureMinDeficitPct then
            supplementMinPct = math.max(supplementMinPct, config.lowPressureMinDeficitPct)
        end
        if deficitPct < supplementMinPct then
            return nil, string.format('supplement_below_min_pct|deficitPct=%.1f minPct=%.1f', deficitPct, supplementMinPct)
        end

        local needsSupplement, gap, supplementDetails = calculateSupplementGap(targetInfo, config)
        if not needsSupplement or gap <= 0 then
            -- HoT is keeping up, no direct heal needed
            return nil, 'hot_covering|' .. (supplementDetails or '')
        end

        -- HoT is not keeping up - need to supplement with a direct heal sized for the gap
        -- Create a modified targetInfo with the gap as the deficit
        local gapTargetInfo = {
            name = targetInfo.name,
            role = targetInfo.role,
            currentHP = targetInfo.currentHP,
            maxHP = targetInfo.maxHP,
            pctHP = targetInfo.pctHP,
            deficit = gap,  -- Use gap instead of full deficit
            recentDps = targetInfo.recentDps,
            isSquishy = targetInfo.isSquishy,
            incomingHotRemaining = 0,  -- Don't double-count HoT
        }

        local supplementHeal = HealSelector.FindEfficientHeal(gapTargetInfo, false, situation)
        if supplementHeal then
            supplementHeal.details = joinDetails(
                supplementHeal.details,
                string.format('trigger=supplement gap=%.0f %s', gap, supplementDetails or '')
            )
            return supplementHeal
        end
        -- No suitable supplement found, fall through to normal selection
    end

    -- For direct heals: skip targets above minHealPct threshold (e.g., don't heal anyone above 90% HP)
    local minHealPct = config.minHealPct or 10
    if lowPressure and nonSquishy and config.lowPressureMinDeficitPct and deficitPct < config.lowPressureMinDeficitPct then
        return nil, 'below_min_pct_low_pressure'
    end
    if nonSquishy and config.nonSquishyMinHealPct and deficitPct < config.nonSquishyMinHealPct then
        return nil, 'below_min_pct_nonsquishy'
    end
    if deficitPct < minHealPct then
        return nil, 'below_min_pct'
    end

    -- Squishy: prefer fast heals when needed
    if targetInfo.isSquishy then
        local squishyHeal = HealSelector.FindHealForSquishy(deficit, not config.quickHealsEmergencyOnly)
        if squishyHeal then
            squishyHeal.details = joinDetails(
                squishyHeal.details,
                string.format('trigger=squishy deficitPct=%.1f', deficitPct)
            )
            return squishyHeal
        end
    end

    -- Multiple hurt targets: allow quick heals for small deficits
    if not config.quickHealsEmergencyOnly and situation.multipleHurt and deficitPct <= config.quickHealMaxPct then
        local heal = HealSelector.FindFastestHeal(deficit)
        if heal then
            heal.details = joinDetails(
                heal.details,
                string.format('trigger=multi_hurt deficitPct=%.1f', deficitPct)
            )
        end
        return heal
    end

    local heal = HealSelector.FindEfficientHeal(targetInfo, false, situation)
    if not heal then
        return nil, 'no_efficient_heal'
    end
    return heal
end

function HealSelector.FindFastestHeal(deficit)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    -- Try fast heals first
    for _, spellName in ipairs(config.spells.fast) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                return {
                    spell = spellName,
                    expected = expected,
                    category = 'fast',
                    details = formatScoreDetails('fastest', 'single', nil),
                }
            end
        end
    end

    -- Fall back to small
    for _, spellName in ipairs(config.spells.small or {}) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                return {
                    spell = spellName,
                    expected = expected,
                    category = 'small',
                    details = formatScoreDetails('fastest', 'single', nil),
                }
            end
        end
    end

    -- Fall back to medium
    for _, spellName in ipairs(config.spells.medium) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                return {
                    spell = spellName,
                    expected = expected,
                    category = 'medium',
                    details = formatScoreDetails('fastest', 'single', nil),
                }
            end
        end
    end

    -- Last resort: large
    for _, spellName in ipairs(config.spells.large) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                return {
                    spell = spellName,
                    expected = expected,
                    category = 'large',
                    details = formatScoreDetails('fastest', 'single', nil),
                }
            end
        end
    end

    -- Learning mode fallback: use first available spell
    if tracker.IsLearning() then
        if #config.spells.fast > 0 then
            return {
                spell = config.spells.fast[1],
                expected = deficit or 0,
                category = 'fast',
                learning = true,
                details = formatScoreDetails('learning_fallback', 'single', nil, {
                    predicted = deficit or 0,
                    expected = deficit or 0,
                }),
            }
        end
    end

    return nil
end

function HealSelector.FindHealForSquishy(deficit, allowFast)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local minCoverage = deficit * (config.squishyCoveragePct / 100)

    -- Find smallest fast heal that covers minimum
    if allowFast then
        for _, spellName in ipairs(config.spells.fast) do
            local expected = tracker.GetExpectedHeal(spellName)
            if expected and expected >= minCoverage then
                local meta = getSpellMeta(spellName)
                if meta and isSpellUsable(spellName, meta) then
                    return {
                        spell = spellName,
                        expected = expected,
                        category = 'fast',
                        details = formatScoreDetails('squishy', 'single', nil),
                    }
                end
            end
        end
    end

    -- Try small if fast doesn't cover
    for _, spellName in ipairs(config.spells.small or {}) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected and expected >= minCoverage then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                return {
                    spell = spellName,
                    expected = expected,
                    category = 'small',
                    details = formatScoreDetails('squishy', 'single', nil),
                }
            end
        end
    end

    -- Try medium if small doesn't cover
    for _, spellName in ipairs(config.spells.medium) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected and expected >= minCoverage then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                return {
                    spell = spellName,
                    expected = expected,
                    category = 'medium',
                    details = formatScoreDetails('squishy', 'single', nil),
                }
            end
        end
    end

    -- Fall back to fastest available
    if allowFast then
        return HealSelector.FindFastestHeal(deficit)
    end
    return nil
end

function HealSelector.FindEfficientHeal(targetInfo, allowFast, situation)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local deficit = targetInfo.deficit
    local maxOverheal = deficit * (1 + config.overhealTolerancePct / 100)
    local maxOverhealRatio = config.maxOverhealRatio or 2.0

    local bestHeal = nil
    local bestScore = -math.huge

    -- Check all heal categories for best match
    local allSpells = {}
    if allowFast then
        for _, s in ipairs(config.spells.fast) do table.insert(allSpells, {name = s, cat = 'fast'}) end
    end
    for _, s in ipairs(config.spells.small or {}) do table.insert(allSpells, {name = s, cat = 'small'}) end
    for _, s in ipairs(config.spells.medium) do table.insert(allSpells, {name = s, cat = 'medium'}) end
    for _, s in ipairs(config.spells.large) do table.insert(allSpells, {name = s, cat = 'large'}) end

    local candidates = preFilterSpells(allSpells, deficit, situation, tracker, config)
    for _, spell in ipairs(candidates) do
        local expected = spell.expected or getExpectedWithFallback(tracker, spell.name, deficit)
        if expected then
            -- Skip if too much overheal
            if expected <= maxOverheal then
                local meta = getSpellMeta(spell.name)
                if meta and isSpellUsable(spell.name, meta) then
                    local score, components, weightsText = scoreSingle(
                        meta,
                        expected,
                        deficit,
                        targetInfo.recentDps,
                        targetInfo.maxHP,
                        situation,
                        targetInfo
                    )
                    if score > bestScore or (score == bestScore and bestHeal and expected < bestHeal.expected) then
                        bestScore = score
                        bestHeal = {
                            spell = spell.name,
                            expected = expected,
                            category = spell.cat,
                            details = formatScoreDetails('efficient', 'single', score, components, weightsText),
                        }
                    end
                end
            end
        end
    end

    if config.preferUnderheal then
        local underheal = findUnderhealCandidate(candidates, deficit, tracker, config)
        if underheal and (not bestHeal or (bestHeal.expected or 0) > deficit) then
            return underheal
        end
    end

    -- If no good match, use smallest that covers BUT only if not excessive overheal
    if not bestHeal then
        for _, spell in ipairs(candidates) do
            local expected = spell.expected or getExpectedWithFallback(tracker, spell.name, deficit)
            if expected and expected >= deficit then
                -- Don't use coverage fallback if heal is way too big for deficit
                if expected <= deficit * maxOverhealRatio then
                    local meta = getSpellMeta(spell.name)
                    if meta and isSpellUsable(spell.name, meta) then
                        return {
                            spell = spell.name,
                            expected = expected,
                            category = spell.cat,
                            details = formatScoreDetails('coverage_fallback', 'single', nil, {
                                predicted = deficit,
                                expected = expected,
                            }),
                        }
                    end
                end
            end
        end
    end

    -- No appropriate heal found - deficit too small for available heals
    return bestHeal
end

function HealSelector.ShouldUseGroupHeal(targets)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    local hasEmergency = false
    local hurtTargets = {}

    for _, t in ipairs(targets) do
        if t.pctHP < config.emergencyPct then
            hasEmergency = true
        end
        if t.deficit > 0 then
            table.insert(hurtTargets, t)
        end
    end

    -- Don't use group heal if someone is in emergency
    if hasEmergency then
        return false, nil
    end

    -- Check if group heal is efficient
    local best = nil
    local bestScore = -math.huge
    for _, spellName in ipairs(config.spells.group) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                local castSec = meta.castTimeMs / 1000
                local predictedTotal = 0
                local eligibleCount = 0
                for _, t in ipairs(hurtTargets) do
                    local predicted = predictedDeficit(t.deficit, t.recentDps, castSec, t.maxHP)
                    if predicted >= expected then
                        eligibleCount = eligibleCount + 1
                        predictedTotal = predictedTotal + predicted
                    end
                end

                if eligibleCount >= config.groupHealMinCount then
                    local totalHealing = expected * eligibleCount
                    local thresholdDeficit = predictedTotal > 0 and predictedTotal or totalHealing
                    if totalHealing >= thresholdDeficit * 0.7 then -- 70% efficiency threshold
                        local score, components = scoreGroup(meta, expected, thresholdDeficit, eligibleCount)
                        if score > bestScore then
                            bestScore = score
                            best = {
                                spell = spellName,
                                expected = expected,
                                targets = eligibleCount,
                                details = formatScoreDetails('group_score', 'group', score, components),
                            }
                        end
                    end
                end
            end
        end
    end

    if best then
        return true, best
    end
    return false, nil
end

function HealSelector.SelectBestHot(targetInfo, useLight)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    -- Use hotLight for non-tanks if available, fall back to regular hot
    local hotList = config.spells.hot
    if useLight and config.spells.hotLight and #config.spells.hotLight > 0 then
        hotList = config.spells.hotLight
    end

    local best = nil
    local bestScore = -math.huge
    for _, spellName in ipairs(hotList) do
        local meta = getSpellMeta(spellName)
        if meta and isSpellUsable(spellName, meta) then
            local ticks = math.max(meta.durationTicks, 1)
            local fallbackTick = math.max(1, math.floor(targetInfo.deficit / ticks))
            local hasData = tracker.GetExpectedHeal(spellName) ~= nil
            local expectedTick = getExpectedWithFallback(tracker, spellName, fallbackTick)
            if expectedTick then
                local score, components = scoreHot(meta, expectedTick, targetInfo.deficit, targetInfo.recentDps, targetInfo.maxHP)
                if score > bestScore then
                    bestScore = score
                    best = {
                        spell = spellName,
                        expected = expectedTick,
                        details = formatScoreDetails(hasData and 'hot_score' or 'hot_learn', 'hot', score, components),
                    }
                end
            end
        end
    end
    return best
end

function HealSelector.SelectBestGroupHot(targets, totalDeficit, hurtCount)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    local best = nil
    local bestScore = -math.huge
    for _, spellName in ipairs(config.spells.groupHot) do
        local meta = getSpellMeta(spellName)
        if meta and isSpellUsable(spellName, meta) then
            local durationSec = math.max(meta.durationTicks * (TICK_MS / 1000), 1)
            local predictedTotal = 0
            for _, t in ipairs(targets) do
                if t.deficit > 0 then
                    local predicted = predictedDeficit(t.deficit, t.recentDps, durationSec, t.maxHP)
                    predictedTotal = predictedTotal + predicted
                end
            end

            local ticks = math.max(meta.durationTicks, 1)
            local fallbackTick = math.max(1, math.floor((totalDeficit or 0) / (ticks * math.max(hurtCount, 1))))
            local hasData = tracker.GetExpectedHeal(spellName) ~= nil
            local expectedTick = getExpectedWithFallback(tracker, spellName, fallbackTick)
            if expectedTick then
                local totalExpected = expectedTick * ticks * hurtCount
                local score, components = scoreGroup(meta, totalExpected / math.max(hurtCount, 1), predictedTotal, hurtCount)
                if score > bestScore then
                    bestScore = score
                    best = {
                        spell = spellName,
                        expected = expectedTick,
                        targets = hurtCount,
                        details = formatScoreDetails(hasData and 'group_hot_score' or 'group_hot_learn', 'groupHot', score, components),
                    }
                end
            end
        end
    end
    return best
end

function HealSelector.SelectBestPromised(targetInfo)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    local best = nil
    local bestScore = -math.huge
    for _, spellName in ipairs(config.spells.promised) do
        local meta = getSpellMeta(spellName)
        if meta and isSpellUsable(spellName, meta) then
            local hasData = tracker.GetExpectedHeal(spellName) ~= nil
            local expected = getExpectedWithFallback(tracker, spellName, targetInfo.deficit)
            if expected then
                local score, components = scorePromised(meta, expected, targetInfo.deficit, targetInfo.recentDps, targetInfo.maxHP)
                if score > bestScore then
                    bestScore = score
                    best = {
                        spell = spellName,
                        expected = expected,
                        details = formatScoreDetails(hasData and 'promised_score' or 'promised_learn', 'promised', score, components),
                    }
                end
            end
        end
    end
    return best
end

function HealSelector.GetLastAction()
    return HealSelector.lastAction
end

function HealSelector.SetLastAction(action)
    HealSelector.lastAction = action
end

return HealSelector
