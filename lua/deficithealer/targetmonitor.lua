-- targetmonitor.lua
local mq = require('mq')

local TargetMonitor = {
    priorityTargets = {},   -- MT/MA from raid
    groupTargets = {},      -- Group members
    damageHistory = {},     -- target -> { timestamps, amounts }
    logDamageHistory = {},  -- target -> { timestamps, amounts }
    mobDamageHistory = {},  -- mobName -> { timestamps, amounts } - damage DEALT by mobs
    lastHP = {},            -- targetName -> lastKnownHP for damage tracking
    damageVariance = {},    -- targetName -> { samples, mean, variance, stddev, meanDps, stddevDps }
    groupNames = {},        -- group member name set for log DPS filtering
    groupMemberPct = {},    -- group member name -> pctHP fallback
    remoteMaxHP = {},       -- targetName -> maxHP from DanNet (cached)
    remoteMaxHPAt = {},     -- targetName -> last refresh time (ms)
    remoteObserveAt = {},   -- targetName|prop -> last observer request time (ms)
    config = nil,           -- Config reference for squishy threshold
}

local function nowMs()
    local tloTime = mq.TLO.Time.MillisecondsSinceEpoch()
    if tloTime then
        if type(tloTime) == 'function' then
            local value = tloTime()
            if value then
                return value
            end
        elseif type(tloTime) == 'number' then
            return tloTime
        end
    end
    return os.time() * 1000
end

function TargetMonitor.Init(cfg)
    TargetMonitor.priorityTargets = {}
    TargetMonitor.groupTargets = {}
    TargetMonitor.damageHistory = {}
    TargetMonitor.logDamageHistory = {}
    TargetMonitor.mobDamageHistory = {}
    TargetMonitor.lastHP = {}
    TargetMonitor.damageVariance = {}
    TargetMonitor.groupNames = {}
    TargetMonitor.groupMemberPct = {}
    TargetMonitor.remoteMaxHP = {}
    TargetMonitor.remoteMaxHPAt = {}
    TargetMonitor.remoteObserveAt = {}
    TargetMonitor.config = cfg
end

local function ensureDanNetObserver(charName, propName)
    if not charName or charName == '' then
        return false
    end
    -- Check if observer is already set (boxhud pattern)
    if mq.TLO.DanNet(charName).ObserveSet(propName)() then
        return true
    end
    -- Throttle observer setup requests
    local key = charName .. '|' .. propName
    local now = nowMs()
    local lastAt = TargetMonitor.remoteObserveAt[key] or 0
    if (now - lastAt) < 5000 then
        return false
    end
    TargetMonitor.remoteObserveAt[key] = now
    mq.cmdf('/dobserve %s -q "%s"', charName, propName)
    return false
end

local function getRemoteMaxHP(targetName)
    if not targetName or targetName == '' then
        return nil
    end

    -- MaxHP rarely changes - cache for 2 minutes
    local now = nowMs()
    local ttlMs = 120000
    local lastAt = TargetMonitor.remoteMaxHPAt[targetName] or 0
    if (now - lastAt) < ttlMs then
        return TargetMonitor.remoteMaxHP[targetName]
    end

    -- Check DanNet availability
    if not mq.TLO.DanNet then
        return TargetMonitor.remoteMaxHP[targetName]
    end
    local dnPlugin = mq.TLO.Plugin('mq2dannet')
    if not dnPlugin or not dnPlugin.IsLoaded() then
        return TargetMonitor.remoteMaxHP[targetName]
    end

    -- Ensure FullNames is off for short name lookups
    if mq.TLO.DanNet.FullNames and mq.TLO.DanNet.FullNames() then
        mq.cmd('/dnet fullnames off')
    end

    -- Following boxhud pattern: mq.TLO.DanNet(name).Observe(query)()
    local propName = 'Me.MaxHPs'
    ensureDanNetObserver(targetName, propName)

    local val = mq.TLO.DanNet(targetName).Observe(propName)()
    if val == 'NULL' or val == '' then
        val = nil
    end
    local num = tonumber(val)
    if num and num > 0 then
        TargetMonitor.remoteMaxHP[targetName] = num
        TargetMonitor.remoteMaxHPAt[targetName] = now
        return num
    end
    return TargetMonitor.remoteMaxHP[targetName]
end

function TargetMonitor.Update()
    -- Update priority targets (MT/MA from raid)
    TargetMonitor.priorityTargets = {}

    if mq.TLO.Raid.Members() > 0 then
        -- Check raid for MT/MA
        local mainTank = mq.TLO.Raid.MainTank()
        local mainAssist = mq.TLO.Raid.MainAssist()

        if mainTank and mainTank() then
            table.insert(TargetMonitor.priorityTargets, {
                name = mainTank(),
                spawn = mq.TLO.Spawn('pc ' .. mainTank()),
                role = 'MT',
            })
        end

        if mainAssist and mainAssist() and mainAssist() ~= mainTank() then
            table.insert(TargetMonitor.priorityTargets, {
                name = mainAssist(),
                spawn = mq.TLO.Spawn('pc ' .. mainAssist()),
                role = 'MA',
            })
        end
    end

    -- Update group targets
    TargetMonitor.groupTargets = {}
    TargetMonitor.groupNames = {}
    TargetMonitor.groupMemberPct = {}
    local groupCount = mq.TLO.Group.Members() or 0

    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member.Name() then
            -- Skip if already in priority targets
            local isPriority = false
            for _, pt in ipairs(TargetMonitor.priorityTargets) do
                if pt.name == member.Name() then
                    isPriority = true
                    break
                end
            end

            if not isPriority then
                table.insert(TargetMonitor.groupTargets, {
                    name = member.Name(),
                    spawn = mq.TLO.Spawn('pc ' .. member.Name()),  -- Consistent with raid targets
                    role = 'Group',
                })
                TargetMonitor.groupNames[member.Name()] = true
            end
            local pct = tonumber(member.PctHPs())
            if pct then
                TargetMonitor.groupMemberPct[member.Name()] = pct
            end
        end
    end

    -- Add self if not already tracked
    local selfName = mq.TLO.Me.Name()
    local selfTracked = false
    for _, pt in ipairs(TargetMonitor.priorityTargets) do
        if pt.name == selfName then selfTracked = true break end
    end
    for _, gt in ipairs(TargetMonitor.groupTargets) do
        if gt.name == selfName then selfTracked = true break end
    end
    if not selfTracked then
        table.insert(TargetMonitor.groupTargets, {
            name = selfName,
            spawn = mq.TLO.Spawn('pc ' .. selfName),  -- Consistent pattern
            role = 'Self',
        })
        TargetMonitor.groupNames[selfName] = true
    end

    -- Track damage by comparing HP changes between updates
    -- This enables proactive HoT triggers based on DPS
    local function trackDamageForTargets(targets)
        for _, t in ipairs(targets) do
            local info = TargetMonitor.GetTargetInfo(t)
            if info then
                local prevHP = TargetMonitor.lastHP[info.name] or info.currentHP
                if info.currentHP < prevHP then
                    local damage = prevHP - info.currentHP
                    TargetMonitor.RecordDamage(info.name, damage)
                end
                TargetMonitor.lastHP[info.name] = info.currentHP
            end
        end
    end

    trackDamageForTargets(TargetMonitor.priorityTargets)
    trackDamageForTargets(TargetMonitor.groupTargets)
end

function TargetMonitor.GetTargetInfo(target)
    -- spawn is a TLO reference (from Spawn(), Me, or member.Spawn)
    -- Calling spawn() returns the spawn ID or nil if invalid
    local spawn = target.spawn
    if not spawn or not spawn() then
        return nil
    end

    -- For non-targeted group members, CurrentHPs/MaxHPs return placeholder values (100/100)
    -- PctHPs is always accurate regardless of targeting
    local currentHP = tonumber(spawn.CurrentHPs()) or 0
    local maxHP = tonumber(spawn.MaxHPs()) or 1
    local pctHP = tonumber(spawn.PctHPs()) or 100

    -- Fallback pctHP from group member cache if TLO returned invalid value
    local fallbackPct = TargetMonitor.groupMemberPct[target.name]
    if (not pctHP or pctHP <= 0 or pctHP > 100) and fallbackPct then
        pctHP = fallbackPct
    end

    -- Get real MaxHP from DanNet observer (cached)
    local remoteMax = getRemoteMaxHP(target.name)

    -- For self, we can get MaxHP directly
    local fallbackMax = nil
    if target.name == mq.TLO.Me.Name() then
        fallbackMax = tonumber(mq.TLO.Me.MaxHPs()) or nil
    end

    local resolvedMax = remoteMax or fallbackMax
    if resolvedMax and resolvedMax > 0 then
        maxHP = resolvedMax
        -- If spawn returned placeholder values (100/100), calculate real currentHP from pctHP
        -- This is the key calculation: currentHP = (pctHP / 100) * maxHP
        if currentHP <= 100 then
            currentHP = math.floor((pctHP / 100) * maxHP)
        end
    end

    local deficit = maxHP - currentHP
    local recentDps = 0
    if TargetMonitor.config and TargetMonitor.config.damageWindowSec then
        recentDps = TargetMonitor.GetCombinedDPS(target.name, TargetMonitor.config.damageWindowSec)
    end

    local classShort = ''
    if spawn.Class and spawn.Class.ShortName then
        classShort = tostring(spawn.Class.ShortName() or '')
    elseif target.name == mq.TLO.Me.Name() then
        classShort = tostring(mq.TLO.Me.Class.ShortName() or '')
    end
    classShort = classShort:upper()

    local isSquishy = false
    local cfg = TargetMonitor.config
    if cfg and cfg.squishyClasses and #cfg.squishyClasses > 0 then
        for _, cls in ipairs(cfg.squishyClasses) do
            if classShort == tostring(cls):upper() then
                isSquishy = true
                break
            end
        end
    else
        local squishyThreshold = (cfg and cfg.squishyMaxHP) or 80000
        isSquishy = maxHP < squishyThreshold
    end
    return {
        name = target.name,
        role = target.role,
        currentHP = currentHP,
        maxHP = maxHP,
        pctHP = pctHP,
        deficit = deficit,
        recentDps = recentDps,
        isSquishy = isSquishy,
    }
end

function TargetMonitor.IsGroupMemberName(name)
    if not name then
        return false
    end
    return TargetMonitor.groupNames[name] == true
end

function TargetMonitor.RecordDamage(targetName, amount)
    if not TargetMonitor.damageHistory[targetName] then
        TargetMonitor.damageHistory[targetName] = {}
    end

    table.insert(TargetMonitor.damageHistory[targetName], {
        timeMs = nowMs(),
        amount = amount,
    })

    -- Keep only last 10 seconds of damage
    local cutoff = nowMs() - 10000
    local history = TargetMonitor.damageHistory[targetName]
    while #history > 0 and history[1].timeMs < cutoff do
        table.remove(history, 1)
    end
end

function TargetMonitor.RecordLogDamage(targetName, amount)
    if not TargetMonitor.logDamageHistory[targetName] then
        TargetMonitor.logDamageHistory[targetName] = {}
    end

    table.insert(TargetMonitor.logDamageHistory[targetName], {
        timeMs = nowMs(),
        amount = amount,
    })

    local cutoff = nowMs() - 10000
    local history = TargetMonitor.logDamageHistory[targetName]
    while #history > 0 and history[1].timeMs < cutoff do
        table.remove(history, 1)
    end
end

function TargetMonitor.UpdateDamageVariance(targetName, windowSec)
    local history = TargetMonitor.damageHistory[targetName]
    if not history or #history < 3 then
        TargetMonitor.damageVariance[targetName] = nil
        return nil
    end

    local cutoff = nowMs() - (windowSec * 1000)
    local samples = {}
    for _, entry in ipairs(history) do
        if entry.timeMs >= cutoff then
            table.insert(samples, entry.amount)
        end
    end

    if #samples < 3 then
        TargetMonitor.damageVariance[targetName] = nil
        return nil
    end

    local sum = 0
    for _, v in ipairs(samples) do
        sum = sum + v
    end
    local mean = sum / #samples

    local varSum = 0
    for _, v in ipairs(samples) do
        varSum = varSum + (v - mean) ^ 2
    end
    local variance = varSum / #samples
    local stddev = math.sqrt(variance)

    local avgInterval = #samples > 0 and (windowSec / #samples) or 0
    local meanDps = avgInterval > 0 and (mean / avgInterval) or 0
    local stddevDps = avgInterval > 0 and (stddev / avgInterval) or 0

    TargetMonitor.damageVariance[targetName] = {
        samples = #samples,
        mean = mean,
        variance = variance,
        stddev = stddev,
        meanDps = meanDps,
        stddevDps = stddevDps,
    }

    return TargetMonitor.damageVariance[targetName]
end

function TargetMonitor.IsBurstDamage(targetName, threshold, windowSec)
    if not targetName then return false end
    local window = windowSec or (TargetMonitor.config and TargetMonitor.config.damageWindowSec) or 6
    local stats = TargetMonitor.UpdateDamageVariance(targetName, window)
    if not stats then return false end

    local recentDps = TargetMonitor.GetRecentDPS(targetName, 2)
    local burstThreshold = stats.meanDps + (stats.stddevDps * (threshold or 1.5))

    return recentDps > burstThreshold
end

function TargetMonitor.GetRecentDPS(targetName, windowSec)
    local history = TargetMonitor.damageHistory[targetName]
    if not history or #history == 0 then
        return 0
    end

    local cutoff = nowMs() - (windowSec * 1000)
    local totalDamage = 0
    local count = 0

    for _, entry in ipairs(history) do
        if entry.timeMs >= cutoff then
            totalDamage = totalDamage + entry.amount
            count = count + 1
        end
    end

    if count == 0 then return 0 end
    return totalDamage / windowSec
end

function TargetMonitor.GetRecentLogDPS(targetName, windowSec)
    local history = TargetMonitor.logDamageHistory[targetName]
    if not history or #history == 0 then
        return 0
    end

    local cutoff = nowMs() - (windowSec * 1000)
    local totalDamage = 0
    local count = 0

    for _, entry in ipairs(history) do
        if entry.timeMs >= cutoff then
            totalDamage = totalDamage + entry.amount
            count = count + 1
        end
    end

    if count == 0 then return 0 end
    return totalDamage / windowSec
end

function TargetMonitor.GetCombinedDPS(targetName, windowSec)
    local hpDps = TargetMonitor.GetRecentDPS(targetName, windowSec)
    local cfg = TargetMonitor.config
    if not cfg or not cfg.useLogDps then
        return hpDps
    end

    local logDps = TargetMonitor.GetRecentLogDPS(targetName, windowSec)
    local hpWeight = cfg.hpDpsWeight or 0.0
    local logWeight = cfg.logDpsWeight or 0.0
    local weightSum = hpWeight + logWeight
    if weightSum <= 0 then
        return logDps > 0 and logDps or hpDps
    end

    return ((hpDps * hpWeight) + (logDps * logWeight)) / weightSum
end

-- Get detailed DPS validation metrics for a target
-- Returns: hpDps, logDps, combinedDps, discrepancy%, hpDamageTotal, logDamageTotal
function TargetMonitor.GetDpsValidation(targetName, windowSec)
    local window = windowSec or (TargetMonitor.config and TargetMonitor.config.damageWindowSec) or 6
    local hpDps = TargetMonitor.GetRecentDPS(targetName, window)
    local logDps = TargetMonitor.GetRecentLogDPS(targetName, window)
    local combinedDps = TargetMonitor.GetCombinedDPS(targetName, window)

    -- Calculate total damage from each source
    local hpTotal = hpDps * window
    local logTotal = logDps * window

    -- Discrepancy: how much log differs from hp (positive = log sees more damage)
    local discrepancy = 0
    if hpDps > 0 then
        discrepancy = ((logDps - hpDps) / hpDps) * 100
    elseif logDps > 0 then
        discrepancy = 100  -- HP sees nothing, log sees damage
    end

    return {
        hpDps = hpDps,
        logDps = logDps,
        combinedDps = combinedDps,
        discrepancy = discrepancy,
        hpTotal = hpTotal,
        logTotal = logTotal,
        windowSec = window,
    }
end

-- Get DPS validation for all tracked targets
function TargetMonitor.GetAllDpsValidation()
    local results = {}
    local cfg = TargetMonitor.config
    local window = (cfg and cfg.damageWindowSec) or 6

    -- Collect all target names from both history tables
    local names = {}
    for name in pairs(TargetMonitor.damageHistory) do
        names[name] = true
    end
    for name in pairs(TargetMonitor.logDamageHistory) do
        names[name] = true
    end

    for name in pairs(names) do
        local validation = TargetMonitor.GetDpsValidation(name, window)
        -- Only include targets with some activity
        if validation.hpDps > 0 or validation.logDps > 0 then
            validation.name = name
            table.insert(results, validation)
        end
    end

    -- Sort by combined DPS descending
    table.sort(results, function(a, b) return a.combinedDps > b.combinedDps end)

    return results
end

-- Record damage dealt BY a mob (for mob DPS tracking)
function TargetMonitor.RecordMobDamage(mobName, amount)
    if not mobName or mobName == '' then return end

    if not TargetMonitor.mobDamageHistory[mobName] then
        TargetMonitor.mobDamageHistory[mobName] = {}
    end

    table.insert(TargetMonitor.mobDamageHistory[mobName], {
        timeMs = nowMs(),
        amount = amount,
    })

    -- Keep only last 30 seconds of damage for mob tracking
    local cutoff = nowMs() - 30000
    local history = TargetMonitor.mobDamageHistory[mobName]
    while #history > 0 and history[1].timeMs < cutoff do
        table.remove(history, 1)
    end
end

-- Get DPS dealt BY a mob over a time window
function TargetMonitor.GetMobDPS(mobName, windowSec)
    if not mobName then return 0 end

    local history = TargetMonitor.mobDamageHistory[mobName]
    if not history or #history == 0 then
        return 0
    end

    windowSec = windowSec or 10
    local cutoff = nowMs() - (windowSec * 1000)
    local totalDamage = 0

    for _, entry in ipairs(history) do
        if entry.timeMs >= cutoff then
            totalDamage = totalDamage + entry.amount
        end
    end

    return totalDamage / windowSec
end

-- Get all mobs actively dealing damage (from log parsing)
-- Returns list sorted by DPS descending
function TargetMonitor.GetActiveMobs(windowSec)
    windowSec = windowSec or (TargetMonitor.config and TargetMonitor.config.damageWindowSec) or 10
    local cutoff = nowMs() - (windowSec * 1000)
    local mobs = {}

    for mobName, history in pairs(TargetMonitor.mobDamageHistory) do
        local totalDamage = 0
        local hasRecentDamage = false

        for _, entry in ipairs(history) do
            if entry.timeMs >= cutoff then
                totalDamage = totalDamage + entry.amount
                hasRecentDamage = true
            end
        end

        if hasRecentDamage and totalDamage > 0 then
            table.insert(mobs, {
                name = mobName,
                dps = totalDamage / windowSec,
                totalDamage = totalDamage,
            })
        end
    end

    -- Sort by DPS descending
    table.sort(mobs, function(a, b) return a.dps > b.dps end)

    return mobs
end

-- Get total incoming DPS from all mobs
function TargetMonitor.GetTotalIncomingDPS(windowSec)
    local mobs = TargetMonitor.GetActiveMobs(windowSec)
    local total = 0
    for _, mob in ipairs(mobs) do
        total = total + mob.dps
    end
    return total
end

-- Get count of aggressive mobs on xtarget (Auto Hater slots) within range
function TargetMonitor.GetXTargetHaterCount(maxRange)
    local count = 0
    local xtargetCount = mq.TLO.Me.XTarget() or 0
    for i = 1, xtargetCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() then
            local targetType = xt.TargetType and xt.TargetType() or ''
            if targetType == 'Auto Hater' then
                -- Check range if specified
                if maxRange then
                    local distance = xt.Distance and xt.Distance() or 0
                    if distance <= maxRange then
                        count = count + 1
                    end
                else
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- Determine if this is a high-pressure situation warranting big HoT
function TargetMonitor.IsHighPressure(config)
    local cfg = config or TargetMonitor.config
    if not cfg then return false end

    local minMobDps = cfg.bigHotMinMobDps or 3000
    local minXtCount = cfg.bigHotMinXTargetCount or 2
    local xtRange = cfg.bigHotXTargetRange or 100

    local totalDps = TargetMonitor.GetTotalIncomingDPS(cfg.damageWindowSec or 6)
    if totalDps >= minMobDps then
        return true, 'mobDps', totalDps
    end

    local xtCount = TargetMonitor.GetXTargetHaterCount(xtRange)
    if xtCount >= minXtCount then
        return true, 'xtarget', xtCount
    end

    return false, nil, nil
end

function TargetMonitor.GetAllTargets()
    local all = {}
    for _, t in ipairs(TargetMonitor.priorityTargets) do
        local info = TargetMonitor.GetTargetInfo(t)
        if info then table.insert(all, info) end
    end
    for _, t in ipairs(TargetMonitor.groupTargets) do
        local info = TargetMonitor.GetTargetInfo(t)
        if info then table.insert(all, info) end
    end
    return all
end

function TargetMonitor.GetPriorityTargets()
    local result = {}
    for _, t in ipairs(TargetMonitor.priorityTargets) do
        local info = TargetMonitor.GetTargetInfo(t)
        if info then table.insert(result, info) end
    end
    return result
end

function TargetMonitor.GetGroupTargets()
    local result = {}
    for _, t in ipairs(TargetMonitor.groupTargets) do
        local info = TargetMonitor.GetTargetInfo(t)
        if info then table.insert(result, info) end
    end
    return result
end

return TargetMonitor
