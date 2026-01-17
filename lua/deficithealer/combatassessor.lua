-- combatassessor.lua
-- Analyzes combat state to inform healing decisions
local mq = require('mq')

local CombatAssessor = {
    config = nil,
    targetMonitor = nil,

    -- Mob tracking
    mobSnapshots = {},      -- mobId -> { hp%, timestamp }[]
    lastMobCount = 0,
    lastAssessmentTime = 0,

    -- Fight state
    currentFight = nil,     -- { startTime, phase, mobs, estimatedDuration, survivalMode }
}

local function nowMs()
    return mq.gettime()
end

local function nowSec()
    return os.time()
end

function CombatAssessor.Init(config, targetMonitor)
    CombatAssessor.config = config
    CombatAssessor.targetMonitor = targetMonitor
    CombatAssessor.Reset()
end

function CombatAssessor.Reset()
    CombatAssessor.mobSnapshots = {}
    CombatAssessor.lastMobCount = 0
    CombatAssessor.lastAssessmentTime = 0
    CombatAssessor.currentFight = nil
end

-- Record a mob's HP% snapshot
function CombatAssessor.RecordMobHP(mobId, mobName, hpPct)
    if not mobId or mobId == 0 then return end

    if not CombatAssessor.mobSnapshots[mobId] then
        CombatAssessor.mobSnapshots[mobId] = {
            name = mobName,
            snapshots = {},
        }
    end

    local now = nowSec()
    local data = CombatAssessor.mobSnapshots[mobId]

    -- Add snapshot
    table.insert(data.snapshots, {
        hpPct = hpPct,
        time = now,
    })

    -- Keep only last 30 seconds of snapshots
    local cutoff = now - 30
    while #data.snapshots > 1 and data.snapshots[1].time < cutoff do
        table.remove(data.snapshots, 1)
    end
end

-- Calculate time-to-kill for a mob based on HP% decline rate
-- Uses smoothed window and filters outliers (heals, regen, target swaps)
-- Returns TTK in seconds, sampleCount, or nil if can't estimate
function CombatAssessor.GetMobTTK(mobId)
    local data = CombatAssessor.mobSnapshots[mobId]
    if not data or #data.snapshots < 2 then
        return nil, 0
    end

    local config = CombatAssessor.config
    local windowSec = (config and config.ttkWindowSec) or 5  -- Use 5 second smoothed window
    local now = os.time()
    local cutoff = now - windowSec

    -- Collect samples within the window
    local samples = {}
    for _, snap in ipairs(data.snapshots) do
        if snap.time >= cutoff then
            table.insert(samples, snap)
        end
    end

    if #samples < 2 then
        return nil, #samples
    end

    -- Calculate HP% changes between consecutive samples, filtering upward jumps (heals/regen)
    local totalHpLoss = 0
    local totalTime = 0
    local validSamples = 0

    for i = 2, #samples do
        local prev = samples[i - 1]
        local curr = samples[i]
        local hpDelta = prev.hpPct - curr.hpPct
        local timeDelta = curr.time - prev.time

        -- Only count HP decreases (ignore heals, regen, upward jumps)
        if hpDelta > 0 and timeDelta > 0 then
            -- Clamp outliers: ignore if HP dropped more than 20% in 1 second (likely target swap)
            local hpLossRate = hpDelta / timeDelta
            if hpLossRate <= 20 then  -- Max 20% HP/sec is reasonable
                totalHpLoss = totalHpLoss + hpDelta
                totalTime = totalTime + timeDelta
                validSamples = validSamples + 1
            end
        end
    end

    if totalTime <= 0 or totalHpLoss <= 0 or validSamples < 1 then
        return nil, #samples
    end

    local hpLossPerSec = totalHpLoss / totalTime
    local currentHpPct = samples[#samples].hpPct

    -- TTK = remaining HP% / smoothed loss rate
    local ttk = currentHpPct / hpLossPerSec
    return ttk, validSamples
end

-- Get all current XTarget mobs with their HP%
function CombatAssessor.GetXTargetMobs()
    local mobs = {}
    local xtCount = mq.TLO.Me.XTarget() or 0

    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() then
            local targetType = xt.TargetType()
            if targetType == 'Auto Hater' or targetType == 'Hater' then
                local id = xt.ID() or 0
                local name = xt.CleanName() or 'Unknown'
                local hpPct = xt.PctHPs() or 0
                local distance = xt.Distance() or 999

                if id > 0 and hpPct > 0 then
                    table.insert(mobs, {
                        id = id,
                        name = name,
                        hpPct = hpPct,
                        distance = distance,
                    })
                end
            end
        end
    end

    return mobs
end

-- Update mob tracking from XTarget
function CombatAssessor.UpdateMobTracking()
    local mobs = CombatAssessor.GetXTargetMobs()
    local currentCount = #mobs

    -- Detect adds
    if currentCount > CombatAssessor.lastMobCount and CombatAssessor.lastMobCount > 0 then
        -- Adds detected - fight duration recalculated automatically
    end
    CombatAssessor.lastMobCount = currentCount

    -- Record HP snapshots for each mob
    for _, mob in ipairs(mobs) do
        CombatAssessor.RecordMobHP(mob.id, mob.name, mob.hpPct)
    end

    -- Clean up dead/gone mobs
    local activeMobIds = {}
    for _, mob in ipairs(mobs) do
        activeMobIds[mob.id] = true
    end

    for mobId in pairs(CombatAssessor.mobSnapshots) do
        if not activeMobIds[mobId] then
            CombatAssessor.mobSnapshots[mobId] = nil
        end
    end

    return mobs
end

-- Calculate DPS as percentage of tank's max HP
-- Returns: dpsPercent (% HP lost per second)
function CombatAssessor.GetDpsPercent(targetInfo)
    if not targetInfo then return 0 end

    local dps = targetInfo.recentDps or 0
    local maxHP = targetInfo.maxHP or 1

    if maxHP <= 0 then return 0 end

    return (dps / maxHP) * 100
end

-- Determine if we're in survival mode (high DPS relative to tank HP)
-- Gates: DPS >= threshold AND (tank not full OR recent damage spike)
-- Avoids false positives when tank is at 100% HP
function CombatAssessor.IsSurvivalMode(targetInfo)
    local config = CombatAssessor.config
    local threshold = (config and config.survivalModeDpsPct) or 5  -- 5% HP/sec default
    local tankFullThreshold = (config and config.survivalModeTankFullPct) or 90

    local dpsPercent = CombatAssessor.GetDpsPercent(targetInfo)

    -- DPS must meet threshold
    if dpsPercent < threshold then
        return false, dpsPercent
    end

    -- Gate: tank must not be at full HP (avoid false positives)
    local tankPct = targetInfo.pctHP or 100
    if tankPct > tankFullThreshold then
        -- Tank is nearly full, not survival mode yet even with high DPS
        -- Exception: if there's a damage spike (high deficit change rate)
        local deficit = targetInfo.deficit or 0
        local deficitPct = (targetInfo.maxHP and targetInfo.maxHP > 0) and (deficit / targetInfo.maxHP * 100) or 0
        if deficitPct < 5 then
            -- Less than 5% deficit and tank nearly full, not survival mode
            return false, dpsPercent
        end
    end

    return true, dpsPercent
end

-- Estimate fight duration based on average mob TTK (ignoring near-dead mobs)
-- Using average instead of minimum prevents one near-dead mob from marking fight as "ending"
-- Returns: estimatedSeconds, mobData[], totalSamples
function CombatAssessor.EstimateFightDuration()
    local mobs = CombatAssessor.UpdateMobTracking()

    if #mobs == 0 then
        return 0, {}, 0
    end

    local config = CombatAssessor.config
    local nearDeadThreshold = (config and config.nearDeadMobPct) or 10  -- Ignore mobs below 10% HP

    local mobData = {}
    local totalTTK = 0
    local ttkCount = 0
    local totalHpPct = 0
    local totalSamples = 0

    for _, mob in ipairs(mobs) do
        local ttk, sampleCount = CombatAssessor.GetMobTTK(mob.id)
        mob.ttk = ttk
        mob.sampleCount = sampleCount or 0
        totalSamples = totalSamples + (sampleCount or 0)
        table.insert(mobData, mob)
        totalHpPct = totalHpPct + mob.hpPct

        -- Only include mobs above near-dead threshold in TTK average
        -- This prevents one dying mob from marking the whole fight as "ending"
        if ttk and ttk > 0 and mob.hpPct > nearDeadThreshold then
            totalTTK = totalTTK + ttk
            ttkCount = ttkCount + 1
        end
    end

    local avgTTK
    if ttkCount > 0 then
        avgTTK = totalTTK / ttkCount
    else
        -- Fallback: estimate from average HP% (assume 30 seconds for a mob at 100% HP)
        local avgHpPct = totalHpPct / #mobs
        avgTTK = (avgHpPct / 100) * 30
    end

    return avgTTK, mobData, totalSamples
end

-- Determine fight phase based on mob HP and TTK
-- Returns: 'starting', 'mid', 'ending', or 'none'
function CombatAssessor.GetFightPhase(mobData, estimatedDuration)
    local config = CombatAssessor.config

    if not mobData or #mobData == 0 then
        return 'none'
    end

    -- Calculate average mob HP%
    local totalHpPct = 0
    for _, mob in ipairs(mobData) do
        totalHpPct = totalHpPct + mob.hpPct
    end
    local avgHpPct = totalHpPct / #mobData

    -- Thresholds (configurable)
    local startingThreshold = (config and config.fightPhaseStartingPct) or 70
    local endingThreshold = (config and config.fightPhaseEndingPct) or 25
    local endingTTK = (config and config.fightPhaseEndingTTK) or 20

    -- Check ending conditions first (TTK or HP%)
    if estimatedDuration < endingTTK or avgHpPct < endingThreshold then
        return 'ending'
    end

    -- Check starting
    if avgHpPct > startingThreshold then
        return 'starting'
    end

    return 'mid'
end

-- Full combat assessment - call this each tick
-- Returns situation-like object with combat context
function CombatAssessor.Assess(tankInfo)
    local now = nowSec()
    local config = CombatAssessor.config

    -- Update mob tracking
    local estimatedDuration, mobData, totalSamples = CombatAssessor.EstimateFightDuration()

    -- Determine survival mode
    local survivalMode, dpsPercent = CombatAssessor.IsSurvivalMode(tankInfo)

    -- Determine fight phase
    local fightPhase = CombatAssessor.GetFightPhase(mobData, estimatedDuration)

    -- Build assessment result
    local assessment = {
        mobCount = #mobData,
        mobs = mobData,
        estimatedDurationSec = estimatedDuration,
        fightPhase = fightPhase,
        survivalMode = survivalMode,
        dpsPercent = dpsPercent,
        timestamp = now,
        -- Validation info
        ttkWindowSec = (config and config.ttkWindowSec) or 5,
        ttkSampleCount = totalSamples,
        tankPct = tankInfo and tankInfo.pctHP or 100,
        tankDeficitPct = (tankInfo and tankInfo.maxHP and tankInfo.maxHP > 0)
            and ((tankInfo.deficit or 0) / tankInfo.maxHP * 100) or 0,
    }

    CombatAssessor.currentFight = assessment
    CombatAssessor.lastAssessmentTime = now

    return assessment
end

-- Check if Promised heal should be allowed based on fight duration and tank state
-- Note: Promised is ALLOWED in survival mode (0.25s cast = fast)
-- The safety floor is raised separately in IsSafeToWaitForPromised
-- Returns: allowed, reason
function CombatAssessor.ShouldAllowPromised(assessment, tankPct)
    if not assessment then return true, nil end

    local config = CombatAssessor.config

    -- Don't use Promised if fight is ending (won't land in time)
    if assessment.fightPhase == 'ending' then
        return false, 'promised_blocked_ending'
    end

    -- Check if fight will last long enough for Promised to land
    local promisedDelay = (config and config.promisedDelaySeconds) or 18
    local buffer = (config and config.promisedDurationBuffer) or 5
    local minDuration = promisedDelay + buffer

    if assessment.estimatedDurationSec < minDuration then
        return false, string.format('promised_blocked_ttk|ttk=%.0f<min=%d', assessment.estimatedDurationSec, minDuration)
    end

    -- Don't START a new Promised if tank is already below the safety floor
    -- (They need direct heals now, not a delayed heal)
    local currentTankPct = tankPct or assessment.tankPct or 100
    local safetyFloor = CombatAssessor.GetPromisedSafetyFloor()
    if currentTankPct < safetyFloor then
        return false, string.format('promised_blocked_floor|tankPct=%.0f<floor=%d', currentTankPct, safetyFloor)
    end

    return true, nil
end

-- Get the safety floor for Promised heals, adjusted for survival mode
function CombatAssessor.GetPromisedSafetyFloor()
    local config = CombatAssessor.config
    local assessment = CombatAssessor.currentFight

    local baseSafetyFloor = (config and config.promisedSafetyFloorPct) or 35
    local survivalSafetyFloor = (config and config.promisedSurvivalSafetyFloorPct) or 55

    -- In survival mode, use higher safety floor since damage can spike
    if assessment and assessment.survivalMode then
        return survivalSafetyFloor
    end

    return baseSafetyFloor
end

-- Check if HoT should be allowed based on fight duration
function CombatAssessor.ShouldAllowHot(assessment, hotDurationSec)
    if not assessment then return true, nil end

    local config = CombatAssessor.config

    -- Allow HoTs when not in combat (no mobs on XTarget)
    -- This prevents blocking HoTs out of combat or when XTarget isn't populated
    if assessment.mobCount == 0 or assessment.fightPhase == 'none' then
        return true, nil
    end

    -- In survival mode, only allow HoT if it's a short/light HoT
    -- Long HoTs waste time casting when we need fast heals
    if assessment.survivalMode then
        local maxHotInSurvival = (config and config.survivalModeMaxHotDuration) or 12
        if hotDurationSec > maxHotInSurvival then
            return false, 'survival_mode_long_hot'
        end
    end

    -- Don't start new HoT if fight is ending
    if assessment.fightPhase == 'ending' then
        return false, 'fight_ending'
    end

    -- Check if fight will last long enough for HoT to be useful
    -- Require at least 50% of HoT duration remaining
    local minEfficiency = (config and config.hotMinFightDurationPct) or 50
    local minDuration = hotDurationSec * (minEfficiency / 100)

    if assessment.estimatedDurationSec < minDuration then
        return false, string.format('ttk_too_short|ttk=%.0f min=%.0f', assessment.estimatedDurationSec, minDuration)
    end

    return true, nil
end

-- Get a formatted summary for logging
function CombatAssessor.GetSummary()
    local fight = CombatAssessor.currentFight
    if not fight then
        return 'no_combat'
    end

    return string.format(
        'phase=%s mobs=%d ttk=%.0fs survival=%s dpsPct=%.1f%%',
        fight.fightPhase,
        fight.mobCount,
        fight.estimatedDurationSec,
        tostring(fight.survivalMode),
        fight.dpsPercent or 0
    )
end

return CombatAssessor
