-- analytics.lua
local mq = require('mq')

local Analytics = {
    session = {
        startTime = 0,
        healsCount = 0,
        totalHealing = 0,
        totalOverheal = 0,
        criticalEvents = 0,
        nearMisses = 0,
        deaths = 0,
        reactionTimes = {},
    },
    history = {},
}

local MAX_REACTION_TIMES = 50
local MAX_HISTORY_SESSIONS = 10

function Analytics.Init(savedHistory)
    Analytics.session = {
        startTime = os.time(),
        healsCount = 0,
        totalHealing = 0,
        totalOverheal = 0,
        criticalEvents = 0,
        nearMisses = 0,
        deaths = 0,
        reactionTimes = {
            small = {},   -- < 20% deficit
            medium = {},  -- 20-50% deficit
            large = {},   -- > 50% deficit
        },
    }

    -- Restore saved history if provided
    if savedHistory and type(savedHistory) == 'table' then
        Analytics.history = savedHistory
    else
        Analytics.history = {}
    end
end

function Analytics.RecordHeal(spellName, healAmount, deficit, targetName)
    if not healAmount or healAmount <= 0 then
        return
    end
    if not deficit or deficit < 0 then
        deficit = 0
    end

    -- Calculate effective healing vs overheal
    local effectiveHeal = math.min(healAmount, deficit)
    local overheal = math.max(0, healAmount - deficit)

    Analytics.session.healsCount = Analytics.session.healsCount + 1
    Analytics.session.totalHealing = Analytics.session.totalHealing + effectiveHeal
    Analytics.session.totalOverheal = Analytics.session.totalOverheal + overheal
end

function Analytics.RecordCriticalEvent(targetName, pctHP)
    Analytics.session.criticalEvents = Analytics.session.criticalEvents + 1
end

function Analytics.RecordNearMiss(targetName, pctHP)
    Analytics.session.nearMisses = Analytics.session.nearMisses + 1
end

function Analytics.RecordDeath(targetName)
    Analytics.session.deaths = Analytics.session.deaths + 1
end

function Analytics.RecordReactionTime(deficitPct, reactionMs)
    if not deficitPct or not reactionMs then
        return
    end

    -- Categorize by deficit severity
    local category
    if deficitPct < 20 then
        category = 'small'
    elseif deficitPct <= 50 then
        category = 'medium'
    else
        category = 'large'
    end

    local times = Analytics.session.reactionTimes[category]
    if not times then
        Analytics.session.reactionTimes[category] = {}
        times = Analytics.session.reactionTimes[category]
    end

    table.insert(times, reactionMs)

    -- Keep only last MAX_REACTION_TIMES per category
    while #times > MAX_REACTION_TIMES do
        table.remove(times, 1)
    end
end

function Analytics.GetOverhealPct()
    local total = Analytics.session.totalHealing + Analytics.session.totalOverheal
    if total == 0 then
        return 0
    end
    return (Analytics.session.totalOverheal / total) * 100
end

function Analytics.GetEfficiency()
    local total = Analytics.session.totalHealing + Analytics.session.totalOverheal
    if total == 0 then
        return 100  -- No healing done = 100% efficient (nothing wasted)
    end
    return (Analytics.session.totalHealing / total) * 100
end

function Analytics.GetAverageReactionTime(category)
    local times = Analytics.session.reactionTimes[category]
    if not times or #times == 0 then
        return nil
    end

    local sum = 0
    for _, t in ipairs(times) do
        sum = sum + t
    end
    return sum / #times
end

function Analytics.GetSessionStats()
    local now = os.time()
    local duration = now - Analytics.session.startTime

    return {
        duration = duration,
        healsCount = Analytics.session.healsCount,
        totalHealing = Analytics.session.totalHealing,
        totalOverheal = Analytics.session.totalOverheal,
        criticalEvents = Analytics.session.criticalEvents,
        nearMisses = Analytics.session.nearMisses,
        deaths = Analytics.session.deaths,
        overhealPct = Analytics.GetOverhealPct(),
        efficiency = Analytics.GetEfficiency(),
        avgReactionSmall = Analytics.GetAverageReactionTime('small'),
        avgReactionMedium = Analytics.GetAverageReactionTime('medium'),
        avgReactionLarge = Analytics.GetAverageReactionTime('large'),
        healsPerMinute = duration > 0 and (Analytics.session.healsCount / (duration / 60)) or 0,
    }
end

function Analytics.SaveSession()
    local stats = Analytics.GetSessionStats()

    -- Add timestamp for when session was saved
    stats.savedAt = os.time()

    table.insert(Analytics.history, stats)

    -- Keep only last MAX_HISTORY_SESSIONS
    while #Analytics.history > MAX_HISTORY_SESSIONS do
        table.remove(Analytics.history, 1)
    end
end

function Analytics.GetHistory()
    return Analytics.history
end

return Analytics
