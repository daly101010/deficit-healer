-- targetmonitor.lua
local mq = require('mq')

local TargetMonitor = {
    priorityTargets = {},   -- MT/MA from raid
    groupTargets = {},      -- Group members
    damageHistory = {},     -- target -> { timestamps, amounts }
    lastHP = {},            -- targetName -> lastKnownHP for damage tracking
    config = nil,           -- Config reference for squishy threshold
}

function TargetMonitor.Init(cfg)
    TargetMonitor.priorityTargets = {}
    TargetMonitor.groupTargets = {}
    TargetMonitor.damageHistory = {}
    TargetMonitor.lastHP = {}
    TargetMonitor.config = cfg
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

    local currentHP = spawn.CurrentHPs() or 0
    local maxHP = spawn.MaxHPs() or 1
    local pctHP = spawn.PctHPs() or 100
    local deficit = maxHP - currentHP

    local squishyThreshold = (TargetMonitor.config and TargetMonitor.config.squishyMaxHP) or 80000
    return {
        name = target.name,
        role = target.role,
        currentHP = currentHP,
        maxHP = maxHP,
        pctHP = pctHP,
        deficit = deficit,
        isSquishy = maxHP < squishyThreshold,
    }
end

function TargetMonitor.RecordDamage(targetName, amount)
    if not TargetMonitor.damageHistory[targetName] then
        TargetMonitor.damageHistory[targetName] = {}
    end

    table.insert(TargetMonitor.damageHistory[targetName], {
        time = os.time(),
        amount = amount,
    })

    -- Keep only last 10 seconds of damage
    local cutoff = os.time() - 10
    local history = TargetMonitor.damageHistory[targetName]
    while #history > 0 and history[1].time < cutoff do
        table.remove(history, 1)
    end
end

function TargetMonitor.GetRecentDPS(targetName, windowSec)
    local history = TargetMonitor.damageHistory[targetName]
    if not history or #history == 0 then
        return 0
    end

    local cutoff = os.time() - windowSec
    local totalDamage = 0
    local count = 0

    for _, entry in ipairs(history) do
        if entry.time >= cutoff then
            totalDamage = totalDamage + entry.amount
            count = count + 1
        end
    end

    if count == 0 then return 0 end
    return totalDamage / windowSec
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
