-- healtracker.lua
local mq = require('mq')

local HealTracker = {
    heals = {},          -- spellName -> { baseAvg, critAvg, critRate, count, ... }
    recentHeals = {},    -- last N heals for trend calculation
    learningMode = true,
}

-- Healing Gift AA crit chance lookup by rank
-- Each rank adds approximately 2-3% crit chance
-- Data from: https://www.raidloot.com/class/cleric#/aa/Archetype/Healing_Gift
local HEALING_GIFT_CRIT_PCT = {
    [0] = 0,
    [1] = 2, [2] = 4, [3] = 7, [4] = 10, [5] = 13,
    [6] = 16, [7] = 18, [8] = 20, [9] = 22, [10] = 24,
    [11] = 26, [12] = 28,  -- Secrets of Faydwer cap
    -- Later expansions add more ranks
    [13] = 30, [14] = 32, [15] = 34, [16] = 36, [17] = 38,
    [18] = 40, [19] = 42, [20] = 44, [21] = 46, [22] = 48,
    [23] = 50, [24] = 52, [25] = 54, [26] = 56, [27] = 58,
    [28] = 60, [29] = 62, [30] = 64, [31] = 66, [32] = 68,
    [33] = 70, [34] = 72, [35] = 74, [36] = 76,
}

-- Healing Adept AA - increases direct heal effectiveness (% bonus)
-- Data from: https://www.raidloot.com/class/cleric#/aa/Archetype/Healing_Adept
local HEALING_ADEPT_BONUS_PCT = {
    [0] = 0,
    [1] = 2, [2] = 5, [3] = 8, [4] = 11, [5] = 14,
    [6] = 17, [7] = 20, [8] = 23, [9] = 26, [10] = 29,
    [11] = 32, [12] = 35, [13] = 38, [14] = 41, [15] = 44,
    [16] = 47, [17] = 50, [18] = 53, [19] = 56, [20] = 59,
    [21] = 62, [22] = 65, [23] = 68, [24] = 71, [25] = 74,
    [26] = 77, [27] = 80, [28] = 83, [29] = 86, [30] = 89,
    [31] = 92, [32] = 95, [33] = 98, [34] = 101, [35] = 104,
    [36] = 107, [37] = 110, [38] = 113, [39] = 116, [40] = 119,
}

-- Healing Boon AA - increases HoT effectiveness (% bonus)
-- Data from: https://www.raidloot.com/class/cleric#/aa/Archetype/Healing_Boon
local HEALING_BOON_BONUS_PCT = {
    [0] = 0,
    [1] = 3, [2] = 6, [3] = 9, [4] = 12, [5] = 15,
    [6] = 18, [7] = 21, [8] = 24, [9] = 27, [10] = 30,
    [11] = 33, [12] = 36, [13] = 39, [14] = 42, [15] = 45,
    [16] = 48, [17] = 51, [18] = 54, [19] = 57, [20] = 60,
}

-- Cache for AA values (refreshed every 60 seconds)
local aaCache = {
    healingGift = nil,
    healingAdept = nil,
    healingBoon = nil,
    lastCheck = 0,
}

local function refreshAACache()
    local now = os.time()
    if aaCache.lastCheck and (now - aaCache.lastCheck) < 60 then
        return  -- Cache still valid
    end

    -- Healing Gift (crit chance)
    local giftAA = mq.TLO.Me.AltAbility('Healing Gift')
    local giftRank = (giftAA and giftAA()) and giftAA.Rank() or 0
    local giftPct = HEALING_GIFT_CRIT_PCT[giftRank]
    if not giftPct then
        giftPct = 76 + ((giftRank - 36) * 2)
        giftPct = math.min(giftPct, 100)
    end
    aaCache.healingGift = giftPct / 100

    -- Healing Adept (direct heal bonus)
    local adeptAA = mq.TLO.Me.AltAbility('Healing Adept')
    local adeptRank = (adeptAA and adeptAA()) and adeptAA.Rank() or 0
    local adeptPct = HEALING_ADEPT_BONUS_PCT[adeptRank]
    if not adeptPct then
        adeptPct = 119 + ((adeptRank - 40) * 3)
    end
    aaCache.healingAdept = 1 + (adeptPct / 100)  -- Store as multiplier (e.g., 1.35)

    -- Healing Boon (HoT bonus)
    local boonAA = mq.TLO.Me.AltAbility('Healing Boon')
    local boonRank = (boonAA and boonAA()) and boonAA.Rank() or 0
    local boonPct = HEALING_BOON_BONUS_PCT[boonRank]
    if not boonPct then
        boonPct = 60 + ((boonRank - 20) * 3)
    end
    aaCache.healingBoon = 1 + (boonPct / 100)  -- Store as multiplier

    aaCache.lastCheck = now
end

-- Get crit chance from Healing Gift AA (returns 0.0 to 1.0)
function HealTracker.GetHealingGiftCritRate()
    refreshAACache()
    return aaCache.healingGift or 0
end

-- Get direct heal bonus multiplier from Healing Adept AA (returns 1.0+)
-- Example: 35% bonus returns 1.35
function HealTracker.GetHealingAdeptMultiplier()
    refreshAACache()
    return aaCache.healingAdept or 1
end

-- Get HoT bonus multiplier from Healing Boon AA (returns 1.0+)
-- Example: 36% bonus returns 1.36
function HealTracker.GetHealingBoonMultiplier()
    refreshAACache()
    return aaCache.healingBoon or 1
end

-- Get all AA modifiers in one call (for efficiency)
function HealTracker.GetAAModifiers()
    refreshAACache()
    return {
        critRate = aaCache.healingGift or 0,
        critPct = (aaCache.healingGift or 0) * 100,
        directHealMult = aaCache.healingAdept or 1,
        directHealBonusPct = ((aaCache.healingAdept or 1) - 1) * 100,
        hotMult = aaCache.healingBoon or 1,
        hotBonusPct = ((aaCache.healingBoon or 1) - 1) * 100,
    }
end

-- Calculate expected heal from spell base value using AA modifiers
-- spellBaseHeal: The spell's base heal value (from spell data)
-- isHot: true for HoT spells, false for direct heals
-- Returns: expected heal amount accounting for AA bonuses and crit chance
function HealTracker.CalculateExpectedFromBase(spellBaseHeal, isHot)
    refreshAACache()

    local critRate = aaCache.healingGift or 0
    local adeptMult = aaCache.healingAdept or 1
    local boonMult = aaCache.healingBoon or 1

    -- Apply appropriate AA bonus
    local bonusMult = isHot and boonMult or adeptMult
    local boostedBase = spellBaseHeal * bonusMult

    -- Apply crit expectation (crits are 2x)
    -- Expected = base * (1 - critRate) + (base * 2) * critRate
    -- Expected = base * (1 - critRate + 2*critRate)
    -- Expected = base * (1 + critRate)
    local expected = boostedBase * (1 + critRate)

    return expected
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
