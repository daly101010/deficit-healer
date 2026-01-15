-- proactive.lua
local mq = require('mq')

local Proactive = {
    config = nil,
    healTracker = nil,
    targetMonitor = nil,
    activeHots = {},      -- targetName -> { spell, expireTime }
    activePromised = {},  -- targetName -> { spell, expireTime }
}

function Proactive.Init(config, healTracker, targetMonitor)
    Proactive.config = config
    Proactive.healTracker = healTracker
    Proactive.targetMonitor = targetMonitor
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
    for _, spellName in ipairs(config.spells.hot) do
        return true, spellName
    end

    return false, nil
end

function Proactive.ShouldApplyPromised(targetInfo, situation)
    local config = Proactive.config

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
    for _, spellName in ipairs(config.spells.promised) do
        return true, spellName
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
