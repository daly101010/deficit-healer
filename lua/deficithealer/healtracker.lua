-- healtracker.lua
local mq = require('mq')

local HealTracker = {
    heals = {},          -- spellName -> { baseAvg, critAvg, critRate, count, ... }
    recentHeals = {},    -- last N heals for trend calculation
    learningMode = true,
}

local function updateLearningMode()
    local reliableCount = 0
    for _, data in pairs(HealTracker.heals) do
        if data.count >= 10 then
            reliableCount = reliableCount + 1
        end
    end
    HealTracker.learningMode = reliableCount < 3
end

function HealTracker.Init(savedData, weight)
    HealTracker.weight = weight or 0.1
    if savedData then
        HealTracker.heals = savedData
        updateLearningMode()
    end
end

function HealTracker.RecordHeal(spellName, amount, isCrit)
    if not spellName or type(spellName) ~= 'string' or spellName == '' then
        return false
    end
    if not amount or type(amount) ~= 'number' or amount <= 0 then
        return false
    end

    isCrit = isCrit or false

    if not HealTracker.heals[spellName] then
        -- Initialize with separate crit/non-crit tracking
        HealTracker.heals[spellName] = {
            -- Legacy fields for backwards compatibility
            avg = amount,
            count = 1,
            trend = 0,
            min = amount,
            max = amount,
            -- Crit tracking
            baseAvg = isCrit and 0 or amount,
            baseCount = isCrit and 0 or 1,
            critAvg = isCrit and amount or 0,
            critCount = isCrit and 1 or 0,
        }
    else
        local data = HealTracker.heals[spellName]
        local oldAvg = data.avg

        -- Update overall stats (legacy)
        data.avg = (data.avg * (1 - HealTracker.weight)) + (amount * HealTracker.weight)
        data.count = data.count + 1
        data.min = math.min(data.min or amount, amount)
        data.max = math.max(data.max or amount, amount)
        data.trend = data.avg - oldAvg

        -- Update crit-specific tracking
        if isCrit then
            data.critCount = (data.critCount or 0) + 1
            if (data.critCount or 0) == 1 then
                data.critAvg = amount
            else
                data.critAvg = ((data.critAvg or 0) * (1 - HealTracker.weight)) + (amount * HealTracker.weight)
            end
        else
            data.baseCount = (data.baseCount or 0) + 1
            if (data.baseCount or 0) == 1 then
                data.baseAvg = amount
            else
                data.baseAvg = ((data.baseAvg or 0) * (1 - HealTracker.weight)) + (amount * HealTracker.weight)
            end
        end
    end

    -- Track recent heals for analytics
    table.insert(HealTracker.recentHeals, {
        spell = spellName,
        amount = amount,
        isCrit = isCrit,
        time = os.time(),
    })

    -- Keep only last 100 heals
    while #HealTracker.recentHeals > 100 do
        table.remove(HealTracker.recentHeals, 1)
    end

    -- Update learning mode
    if HealTracker.learningMode then
        updateLearningMode()
    end
end

function HealTracker.GetExpectedHeal(spellName)
    local data = HealTracker.heals[spellName]
    if not data or data.count < 3 then
        return nil -- Not enough data
    end

    -- If we have crit tracking data, calculate expected value properly
    local baseCount = data.baseCount or 0
    local critCount = data.critCount or 0
    local totalCount = baseCount + critCount

    if totalCount >= 3 and baseCount > 0 then
        local critRate = critCount / totalCount
        local baseAvg = data.baseAvg or data.avg
        local critAvg = data.critAvg or (baseAvg * 2)  -- Default crit to 2x base

        -- Expected value = base * (1 - critRate) + crit * critRate
        return (baseAvg * (1 - critRate)) + (critAvg * critRate)
    end

    -- Fall back to simple average if no crit data
    return data.avg
end

-- Get crit rate for a spell (0.0 to 1.0)
function HealTracker.GetCritRate(spellName)
    local data = HealTracker.heals[spellName]
    if not data then return 0 end

    local baseCount = data.baseCount or 0
    local critCount = data.critCount or 0
    local totalCount = baseCount + critCount

    if totalCount < 3 then return 0 end
    return critCount / totalCount
end

-- Get detailed heal stats including crit info
function HealTracker.GetDetailedStats(spellName)
    local data = HealTracker.heals[spellName]
    if not data then return nil end

    local baseCount = data.baseCount or 0
    local critCount = data.critCount or 0
    local totalCount = baseCount + critCount
    local critRate = totalCount > 0 and (critCount / totalCount) or 0

    return {
        baseAvg = data.baseAvg or data.avg,
        critAvg = data.critAvg or 0,
        critRate = critRate,
        critPct = critRate * 100,
        totalCount = totalCount,
        baseCount = baseCount,
        critCount = critCount,
        expected = HealTracker.GetExpectedHeal(spellName),
        min = data.min,
        max = data.max,
    }
end

function HealTracker.GetHealData(spellName)
    return HealTracker.heals[spellName]
end

function HealTracker.GetAllData()
    return HealTracker.heals
end

function HealTracker.IsLearning()
    return HealTracker.learningMode
end

function HealTracker.GetData()
    return HealTracker.heals
end

function HealTracker.Reset()
    HealTracker.heals = {}
    HealTracker.recentHeals = {}
    HealTracker.learningMode = true
    print('[DeficitHealer] Heal data reset')
end

function HealTracker.ResetSpell(spellName)
    if HealTracker.heals[spellName] then
        HealTracker.heals[spellName] = nil
        updateLearningMode()
        print('[DeficitHealer] Reset data for: ' .. spellName)
    end
end

return HealTracker
