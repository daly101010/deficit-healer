-- healtracker.lua
local mq = require('mq')

local HealTracker = {
    heals = {},          -- spellName -> { avg, count, trend }
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

function HealTracker.RecordHeal(spellName, amount)
    if not spellName or type(spellName) ~= 'string' or spellName == '' then
        return false
    end
    if not amount or type(amount) ~= 'number' or amount <= 0 then
        return false
    end

    if not HealTracker.heals[spellName] then
        HealTracker.heals[spellName] = {
            avg = amount,
            count = 1,
            trend = 0,
            min = amount,
            max = amount,
        }
    else
        local data = HealTracker.heals[spellName]
        local oldAvg = data.avg

        -- Weighted running average
        data.avg = (data.avg * (1 - HealTracker.weight)) + (amount * HealTracker.weight)
        data.count = data.count + 1
        data.min = math.min(data.min, amount)
        data.max = math.max(data.max, amount)

        -- Trend: positive = heals getting bigger
        data.trend = data.avg - oldAvg
    end

    -- Track recent heals for analytics
    table.insert(HealTracker.recentHeals, {
        spell = spellName,
        amount = amount,
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
    if data and data.count >= 3 then
        return data.avg
    end
    return nil -- Not enough data
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

return HealTracker
