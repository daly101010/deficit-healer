-- config.lua
local mq = require('mq')

local Config = {
    _version = '1.0',

    -- Thresholds
    emergencyPct = 25,              -- Below this = emergency heal
    minHealPct = 10,                -- Don't heal anyone above this % HP (90% = only heal below 90%)
    maxOverhealRatio = 2.0,         -- Skip heal if it would be more than 2x the deficit
    groupHealMinCount = 3,          -- Min people for group heal
    squishyMaxHP = 80000,           -- Legacy HP-based squishy threshold (used only if squishyClasses not set)
    squishyClasses = { 'WIZ', 'ENC', 'NEC', 'MAG'}, -- Class-based squishies

    -- Heal Selection
    scoringPresets = {
        emergency = { coverage = 4.0, manaEff = 0.1, overheal = -0.5 },  -- Speed > efficiency
        normal = { coverage = 2.0, manaEff = 1.0, overheal = -1.5 },     -- Balanced
        lowPressure = { coverage = 1.0, manaEff = 2.0, overheal = -2.0 }, -- Efficiency focus
    },
    nonSquishyMinHealPct = 15,      -- Non-squishies must be missing at least this % to heal
    nonSquishyHotMinDeficitPct = 10, -- Non-squishies must be missing at least this % to consider HoTs
    lowPressureMobCount = 1,        -- Active mobs <= this and only 1 hurt = low pressure
    lowPressureMinDeficitPct = 18,  -- Non-squishies must be missing at least this % under low pressure
    lowPressureHotMinDeficitPct = 12, -- Non-squishies must be missing at least this % for HoTs under low pressure
    squishyCoveragePct = 70,        -- Min deficit coverage for squishies
    overhealTolerancePct = 20,      -- Acceptable overheal
    preferUnderheal = true,         -- Prefer slightly underhealing vs slight overheal
    underhealMinCoveragePct = 80,   -- Min % of deficit to allow underheal choice

    -- HoT Behavior
    damageWindowSec = 6,            -- Seconds to track damage intake
    sustainedDamageThreshold = 5000, -- Max DPS for low-DPS HoT preference
    hotEnabled = true,              -- Master enable for HoTs
    hotMinDps = 100,                -- Minimum DPS to trigger HoT (skip if no real damage)
    hotSupplementMinDps = 100,      -- Minimum DPS to allow direct-heal supplement while HoT is active
    hotMinDeficitPct = 5,           -- OR minimum deficit % to allow HoT (even without DPS)
    quickHealMaxPct = 15,           -- Max missing HP% to allow quick heals outside emergencies
    hotMaxDeficitPct = 25,          -- Max missing HP% to prefer HoTs at low DPS
    hotPreferUnderDps = 3000,       -- Prefer HoT when DPS below this
    hotRefreshWindowPct = 25,       -- Refresh HoT when < 25% duration left
    hotMinDpsForNonTank = 500,      -- Non-tanks must have this much sustained DPS to receive HoTs

    -- Big HoT (hot) vs Light HoT (hotLight) selection
    -- Default to light HoT for everyone; big HoT only in high-pressure situations
    bigHotMinMobDps = 3000,         -- Use big HoT when total incoming mob DPS exceeds this
    bigHotMinXTargetCount = 4,      -- Use big HoT when xtarget count >= this (>3 mobs = long fight)
    bigHotXTargetRange = 100,       -- Only count xtarget mobs within this range
    hotTypicalDuration = 36,        -- Typical HoT duration in seconds (for fight duration checks)
    hotLearnForce = true,           -- Allow HoT casting for learning baseline
    hotLearnMaxDeficitPct = 35,     -- Max missing HP% to force HoTs while learning
    hotLearnIntervalSec = 30,       -- Min seconds between forced HoTs per target
    quickHealsEmergencyOnly = true, -- Restrict quick heals to emergencies only

    -- Promised Heal Behavior
    promisedEnabled = true,         -- Enable Promised heals
    promisedDelaySeconds = 18,      -- Delay before Promised heal lands (spell-specific)
    promisedSafetyFloorPct = 35,    -- Min HP% to maintain while waiting for Promised (normal)
    promisedSurvivalSafetyFloorPct = 55, -- Min HP% in survival mode (higher due to spike damage risk)
    promisedRolling = true,         -- Keep Promised rolling on MT (cast new one when previous lands)
    promisedDurationBuffer = 5,     -- Extra seconds buffer when checking if fight lasts long enough

    -- Combat Assessment (fight duration and survival mode)
    survivalModeDpsPct = 5,         -- DPS as % of tank HP/sec to trigger survival mode (5 = 5%/sec)
    survivalModeTankFullPct = 90,   -- Tank HP% above this gates survival mode (avoid false positives)
    ttkWindowSec = 5,               -- Smoothed window for TTK calculation (seconds)
    nearDeadMobPct = 10,            -- Ignore mobs below this HP% when calculating avg TTK
    fightPhaseStartingPct = 70,     -- Avg mob HP% above this = fight starting
    fightPhaseEndingPct = 25,       -- Avg mob HP% below this = fight ending
    fightPhaseEndingTTK = 20,       -- TTK below this seconds = fight ending
    hotMinFightDurationPct = 50,    -- Require fight to last at least this % of HoT duration
    survivalModeMaxHotDuration = 12, -- Max HoT duration allowed in survival mode (fast HoTs only)

    -- Spell Ducking (cancel mid-cast if target is healed by someone else)
    duckEnabled = true,             -- Enable spell ducking
    duckHpThreshold = 85,           -- Duck direct heals if target HP goes above this %
    duckEmergencyThreshold = 70,    -- Don't duck emergency heals unless above this %
    duckHotThreshold = 92,          -- HoTs have higher threshold (low mana, meant for topping off)
    duckBufferPct = 0.5,            -- Extra buffer above threshold before ducking
    considerIncomingHot = true,     -- Reduce/skip direct heals when our HoT is expected to cover deficit
    hotIncomingCoveragePct = 100,   -- Incoming HoT coverage % needed to skip direct heals
    debugLogging = false,           -- Enable decision logging
    fileLogging = true,             -- Enable detailed log file output
    fileLogLevel = 'debug',         -- trace|debug|info|warn|error
    fileLogPath = '',               -- Empty = mq.configDir
    fileLogName = '',               -- Empty = deficithealer_<char>_log.txt
    fileLogTickMs = 1000,           -- Summary log interval (ms), 0 disables
    fileLogSkipThrottleMs = 2000,   -- Throttle repeated skip logs per target/reason
    dpsValidationLogMs = 5000,      -- DPS validation log interval (ms), 0 disables
    useLogDps = true,               -- Include log-based DPS tracking
    hpDpsWeight = 0.4,              -- Weight for HP-delta DPS
    logDpsWeight = 0.6,             -- Weight for log DPS
    burstStddevMultiplier = 1.5,    -- Burst threshold: mean + (stddev * multiplier)
    burstDpsScale = 1.5,            -- DPS multiplier when burst detected

    -- Learning
    learningWeight = 0.1,           -- Weight for new heal data
    minSamplesForReliable = 10,     -- Samples before data is trusted

    -- Spells (user configures these)
    spells = {
        fast = {},      -- Fast single target (remedies) - emergency only
        small = {},     -- Small single target (light line) - for small deficits
        medium = {},    -- Medium single target
        large = {},     -- Large single target
        group = {},     -- Group heals
        hot = {},       -- Heal over time (for tanks in high-pressure)
        hotLight = {},  -- Light HoT for non-tanks (lower rank, less mana waste on small deficits)
        groupHot = {},  -- Group heal over time
        promised = {},  -- Promised heals
    },
}

-- Helper to serialize tables (defined BEFORE Config.Save where it's used)
local function serializeTable(t, indent)
    indent = indent or '    '
    local result = '{\n'
    for k, v in pairs(t) do
        local key = type(k) == 'string' and k or '[' .. k .. ']'
        if type(v) == 'table' then
            result = result .. indent .. '    ' .. key .. ' = ' .. serializeTable(v, indent .. '    ') .. ',\n'
        elseif type(v) == 'string' then
            result = result .. indent .. '    ' .. key .. ' = "' .. v .. '",\n'
        else
            result = result .. indent .. '    ' .. key .. ' = ' .. tostring(v) .. ',\n'
        end
    end
    result = result .. indent .. '}'
    return result
end

function Config.Load(charName)
    if not charName or charName == '' then
        return Config
    end

    local configPath = mq.configDir .. '/deficithealer_' .. charName .. '.lua'
    local f = io.open(configPath, 'r')
    if f then
        f:close()
        local ok, saved = pcall(dofile, configPath)
        if ok and saved and type(saved) == 'table' then
            for k, v in pairs(saved) do
                if Config[k] ~= nil then
                    -- Special handling for spells: merge instead of replace
                    -- This preserves empty categories that weren't saved
                    if k == 'spells' and type(v) == 'table' then
                        for cat, spellList in pairs(v) do
                            Config.spells[cat] = spellList
                        end
                    else
                        Config[k] = v
                    end
                end
            end
        end
    end
    Config.spells.groupHot = Config.spells.groupHot or {}
    Config.FilterSpells()
    return Config
end

function Config.Save(charName)
    if not charName or charName == '' then
        return false
    end

    Config.FilterSpells()

    local configPath = mq.configDir .. '/deficithealer_' .. charName .. '.lua'
    local f = io.open(configPath, 'w')
    if f then
        f:write('return {\n')
        for k, v in pairs(Config) do
            if type(v) ~= 'function' and k ~= '_version' then
                if type(v) == 'table' then
                    f:write(string.format('    %s = %s,\n', k, serializeTable(v)))
                elseif type(v) == 'string' then
                    f:write(string.format('    %s = "%s",\n', k, v))
                else
                    f:write(string.format('    %s = %s,\n', k, tostring(v)))
                end
            end
        end
        f:write('}\n')
        f:close()
    end
end

local function getSpell(spellName)
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() then
        return spell
    end
    return nil
end

local function normalizeText(value)
    if not value then
        return ''
    end
    if type(value) ~= 'string' then
        value = tostring(value)
    end
    return value:lower():gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
end

local function isSingleTarget(targetType)
    local t = normalizeText(targetType)
    return t == 'single' or t:match('^single') ~= nil
end

local function isGroupV1(targetType)
    local t = normalizeText(targetType)
    return t:match('^group v1') ~= nil
end

local function getCastTimeMs(spell)
    local mySpell = mq.TLO.Me.Spell(spell.Name())
    if mySpell and mySpell() then
        local myCastTime = tonumber(mySpell.MyCastTime())
        if myCastTime then
            return myCastTime
        end
    end
    local castTime = tonumber(spell.CastTime())
    if castTime then
        return castTime
    end
    return nil
end

function Config.IsValidSpellForCategory(category, spellName)
    local spell = getSpell(spellName)
    if not spell then
        return false
    end

    local subcategory = normalizeText(spell.Subcategory())
    local targetType = normalizeText(spell.TargetType())

    if category == 'hot' or category == 'hotLight' then
        return subcategory == 'duration heals' and isSingleTarget(targetType)
    elseif category == 'groupHot' then
        return subcategory == 'duration heals' and isGroupV1(targetType)
    elseif category == 'group' then
        return subcategory == 'heals' and isGroupV1(targetType)
    elseif category == 'promised' then
        return subcategory == 'delayed' and isSingleTarget(targetType)
    elseif category == 'fast' or category == 'small' or category == 'medium' or category == 'large' then
        if category == 'fast' then
            return subcategory == 'quick heal' and isSingleTarget(targetType)
        end
        if not isSingleTarget(targetType) then
            return false
        end
        if category == 'small' or category == 'medium' then
            -- Allow any single-target heals (including quick heal) so users can pick remedy/light lines.
            return subcategory == 'heals' or subcategory == 'quick heal'
        end
        if subcategory ~= 'heals' then
            return false
        end
        local castTimeMs = getCastTimeMs(spell)
        if not castTimeMs then
            return false
        end
        return castTimeMs > 2000
    end

    return true
end

function Config.FilterSpells()
    if not Config.spells then
        return
    end
    for category, spells in pairs(Config.spells) do
        for i = #spells, 1, -1 do
            if not Config.IsValidSpellForCategory(category, spells[i]) then
                table.remove(spells, i)
            end
        end
    end
end

-- Check if a spell is configured in any category
function Config.IsConfiguredSpell(spellName)
    if not Config.spells or not spellName then
        return false
    end
    for _, spells in pairs(Config.spells) do
        for _, name in ipairs(spells) do
            if name == spellName then
                return true
            end
        end
    end
    return false
end

return Config
