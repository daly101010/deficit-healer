-- proactive.lua
local mq = require('mq')

local Proactive = {
    config = nil,
    healTracker = nil,
    targetMonitor = nil,
    healSelector = nil,
    activeHots = {},      -- targetName -> { spell, expireTime }
    activePromised = {},  -- targetName -> { spell, expireTime }
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
    Proactive.activeHots[targetName] = {
        spell = spellName,
        expireTime = os.time() + duration,
    }
end

function Proactive.RecordPromised(targetName, spellName, duration)
    Proactive.activePromised[targetName] = {
        spell = spellName,
        expireTime = os.time() + duration,
    }
end

function Proactive.HasActiveHot(targetName)
    local data = Proactive.activeHots[targetName]
    return data and data.expireTime > os.time()
end

function Proactive.HasActivePromised(targetName)
    local data = Proactive.activePromised[targetName]
    return data and data.expireTime > os.time()
end

function Proactive.ShouldApplyHot(targetInfo)
    local config = Proactive.config
    local monitor = Proactive.targetMonitor
    local selector = Proactive.healSelector

    -- Don't apply if already has HoT
    if Proactive.HasActiveHot(targetInfo.name) then
        return false, nil
    end

    -- Don't apply if no deficit
    if targetInfo.deficit <= 0 then
        return false, nil
    end

    -- Check for sustained damage
    local dps = monitor.GetRecentDPS(targetInfo.name, config.damageWindowSec)
    if dps < config.sustainedDamageThreshold then
        return false, nil
    end

    -- Find appropriate HoT
    if selector and selector.SelectBestHot then
        local best = selector.SelectBestHot(targetInfo)
        if best then
            return true, best.spell
        end
    else
        for _, spellName in ipairs(config.spells.hot) do
            return true, spellName
        end
    end

    return false, nil
end

function Proactive.ShouldApplyGroupHot(targets, situation)
    local config = Proactive.config
    local selector = Proactive.healSelector

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
            return true, best.spell, totalDeficit, best.targets or hurtCount
        end
    end

    return false, nil, nil, nil
end

function Proactive.ShouldApplyPromised(targetInfo, situation)
    local config = Proactive.config
    local selector = Proactive.healSelector

    -- Only for tanks (priority targets)
    if targetInfo.role ~= 'MT' and targetInfo.role ~= 'MA' then
        return false, nil
    end

    -- Don't apply if already has Promised
    if Proactive.HasActivePromised(targetInfo.name) then
        return false, nil
    end

    -- Only apply when stable (no emergency)
    if situation.hasEmergency then
        return false, nil
    end

    -- Only apply when tank is reasonably healthy
    if targetInfo.pctHP < 50 then
        return false, nil
    end

    -- Find appropriate Promised heal
    if selector and selector.SelectBestPromised then
        local best = selector.SelectBestPromised(targetInfo)
        if best then
            return true, best.spell
        end
    else
        for _, spellName in ipairs(config.spells.promised) do
            return true, spellName
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
