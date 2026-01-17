-- healtracker.lua
local mq = require('mq')

local HealTracker = {
    heals = {},          -- spellName -> { baseAvg, critAvg, critRate, count, ... }
    recentHeals = {},    -- last N heals for trend calculation
    learningMode = true,
    cachedHealingGiftRate = nil,  -- Cached AA-based crit rate
    lastAACheck = 0,              -- Last time we checked the AA
}

-- Healing Gift AA crit chance lookup by rank
-- Each rank adds approximately 2-3% crit chance
-- Data from: https://www.raidloot.com/class/cleric#/aa/Archetype/Healing_Gift
local HEALING_GIFT_CRIT_PCT = {
    [0] = 0,
    [1] = 2, [2] = 4, [3] = 7, [4] = 10, [5] = 13,
    [6] = 16, [7] = 18, [8] = 20, [9] = 22, [10] = 24,
    [11] = 26, [12] = 28,  -- Secrets of Faydwer cap shown in screenshot
    -- Later expansions add more ranks
    [13] = 30, [14] = 32, [15] = 34, [16] = 36, [17] = 38,
    [18] = 40, [19] = 42, [20] = 44, [21] = 46, [22] = 48,
    [23] = 50, [24] = 52, [25] = 54, [26] = 56, [27] = 58,
    [28] = 60, [29] = 62, [30] = 64, [31] = 66, [32] = 68,
    [33] = 70, [34] = 72, [35] = 74, [36] = 76,
}

-- Get crit chance from Healing Gift AA (returns 0.0 to 1.0)
-- Caches the result for 60 seconds to avoid repeated TLO calls
function HealTracker.GetHealingGiftCritRate()
    local now = os.time()

    -- Use cached value if recent (AA doesn't change often)
    if HealTracker.cachedHealingGiftRate and (now - HealTracker.lastAACheck) < 60 then
        return HealTracker.cachedHealingGiftRate
    end

    local aa = mq.TLO.Me.AltAbility('Healing Gift')
    if not aa or not aa() then
        HealTracker.cachedHealingGiftRate = 0
        HealTracker.lastAACheck = now
        return 0
    end

    local rank = aa.Rank() or 0
    local critPct = HEALING_GIFT_CRIT_PCT[rank]

    -- If rank is higher than our table, extrapolate (2% per rank)
    if not critPct then
        local maxKnownRank = 36
        local maxKnownPct = 76
        critPct = maxKnownPct + ((rank - maxKnownRank) * 2)
        critPct = math.min(critPct, 100)  -- Cap at 100%
    end

    HealTracker.cachedHealingGiftRate = critPct / 100
    HealTracker.lastAACheck = now
    return HealTracker.cachedHealingGiftRate
end

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

    -- Use AA-based crit rate (more accurate than empirical tracking)
    local critRate = HealTracker.GetHealingGiftCritRate()

    -- Get base heal amount (non-crit average, or fall back to overall avg)
    local baseAvg = data.baseAvg
    if not baseAvg or baseAvg <= 0 then
        -- No non-crit data yet, estimate from overall average
        -- If we only have crits, divide by 2 to estimate base
        if data.critAvg and data.critAvg > 0 and (data.baseCount or 0) == 0 then
            baseAvg = data.critAvg / 2
        else
            baseAvg = data.avg
        end
    end

    -- Crit heals are 2x base (per Healing Gift AA description)
    local critAvg = baseAvg * 2

    -- If we have actual crit data, use it instead
    if data.critAvg and data.critAvg > 0 then
        critAvg = data.critAvg
    end

    -- Expected value = base * (1 - critRate) + crit * critRate
    return (baseAvg * (1 - critRate)) + (critAvg * critRate)
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
    local empiricalCritRate = totalCount > 0 and (critCount / totalCount) or 0
    local aaCritRate = HealTracker.GetHealingGiftCritRate()

    return {
        baseAvg = data.baseAvg or data.avg,
        critAvg = data.critAvg or 0,
        critRate = aaCritRate,           -- Use AA-based rate as primary
        critPct = aaCritRate * 100,
        empiricalCritRate = empiricalCritRate,
        empiricalCritPct = empiricalCritRate * 100,
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
