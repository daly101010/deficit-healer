-- healselector.lua
local mq = require('mq')

local HealSelector = {
    config = nil,
    healTracker = nil,
    lastAction = nil,
}

function HealSelector.Init(config, healTracker)
    HealSelector.config = config
    HealSelector.healTracker = healTracker
end

-- Find best heal for a given target and deficit
function HealSelector.SelectHeal(targetInfo, situation)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local deficit = targetInfo.deficit

    if deficit <= 0 then return nil end

    -- Emergency: anyone below threshold gets fastest heal
    if targetInfo.pctHP < config.emergencyPct then
        return HealSelector.FindFastestHeal(deficit)
    end

    -- Squishy: prefer fast heals
    if targetInfo.isSquishy then
        return HealSelector.FindHealForSquishy(deficit)
    end

    -- Tank: can use slower, more efficient heals
    -- Unless multiple people need healing
    if situation.multipleHurt then
        return HealSelector.FindFastestHeal(deficit)
    end

    return HealSelector.FindEfficientHeal(deficit)
end

function HealSelector.FindFastestHeal(deficit)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    -- Try fast heals first
    for _, spellName in ipairs(config.spells.fast) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            return { spell = spellName, expected = expected, category = 'fast' }
        end
    end

    -- Fall back to medium
    for _, spellName in ipairs(config.spells.medium) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            return { spell = spellName, expected = expected, category = 'medium' }
        end
    end

    -- Last resort: large
    for _, spellName in ipairs(config.spells.large) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            return { spell = spellName, expected = expected, category = 'large' }
        end
    end

    -- Learning mode fallback: use first available spell
    if tracker.IsLearning() then
        if #config.spells.fast > 0 then
            return { spell = config.spells.fast[1], expected = 0, category = 'fast', learning = true }
        end
    end

    return nil
end

function HealSelector.FindHealForSquishy(deficit)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local minCoverage = deficit * (config.squishyCoveragePct / 100)

    -- Find smallest fast heal that covers minimum
    for _, spellName in ipairs(config.spells.fast) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected and expected >= minCoverage then
            return { spell = spellName, expected = expected, category = 'fast' }
        end
    end

    -- Try medium if fast doesn't cover
    for _, spellName in ipairs(config.spells.medium) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected and expected >= minCoverage then
            return { spell = spellName, expected = expected, category = 'medium' }
        end
    end

    -- Fall back to fastest available
    return HealSelector.FindFastestHeal(deficit)
end

function HealSelector.FindEfficientHeal(deficit)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local maxOverheal = deficit * (1 + config.overhealTolerancePct / 100)

    local bestHeal = nil
    local bestMatch = math.huge

    -- Check all heal categories for best match
    local allSpells = {}
    for _, s in ipairs(config.spells.fast) do table.insert(allSpells, {name = s, cat = 'fast'}) end
    for _, s in ipairs(config.spells.medium) do table.insert(allSpells, {name = s, cat = 'medium'}) end
    for _, s in ipairs(config.spells.large) do table.insert(allSpells, {name = s, cat = 'large'}) end

    for _, spell in ipairs(allSpells) do
        local expected = tracker.GetExpectedHeal(spell.name)
        if expected then
            -- Skip if too much overheal
            if expected <= maxOverheal then
                -- Find closest match to deficit
                local diff = math.abs(expected - deficit)
                if diff < bestMatch then
                    bestMatch = diff
                    bestHeal = { spell = spell.name, expected = expected, category = spell.cat }
                end
            end
        end
    end

    -- If no good match, use smallest that covers
    if not bestHeal then
        for _, spell in ipairs(allSpells) do
            local expected = tracker.GetExpectedHeal(spell.name)
            if expected and expected >= deficit then
                return { spell = spell.name, expected = expected, category = spell.cat }
            end
        end
    end

    return bestHeal or HealSelector.FindFastestHeal(deficit)
end

function HealSelector.ShouldUseGroupHeal(targets)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    -- Count people with significant deficit
    local hurtCount = 0
    local totalDeficit = 0
    local hasEmergency = false

    for _, t in ipairs(targets) do
        if t.pctHP < config.emergencyPct then
            hasEmergency = true
        end
        if t.deficit >= config.groupHealMinDeficit then
            hurtCount = hurtCount + 1
            totalDeficit = totalDeficit + t.deficit
        end
    end

    -- Don't use group heal if someone is in emergency
    if hasEmergency then
        return false, nil
    end

    -- Check if we meet count threshold
    if hurtCount < config.groupHealMinCount then
        return false, nil
    end

    -- Check if group heal is efficient
    for _, spellName in ipairs(config.spells.group) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            local totalHealing = expected * hurtCount
            if totalHealing >= totalDeficit * 0.7 then -- 70% efficiency threshold
                return true, { spell = spellName, expected = expected, targets = hurtCount }
            end
        end
    end

    return false, nil
end

function HealSelector.GetLastAction()
    return HealSelector.lastAction
end

function HealSelector.SetLastAction(action)
    HealSelector.lastAction = action
end

return HealSelector
