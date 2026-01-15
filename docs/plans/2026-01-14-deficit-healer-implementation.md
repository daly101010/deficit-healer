# Deficit-Based Healer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a cleric healing Lua script that selects heals based on raw HP deficit instead of percentage, with self-learning heal values and performance analytics.

**Architecture:** Modular design with separate components for heal tracking, target monitoring, heal selection, and analytics. Main loop polls targets, selects heals, and updates UI. Data persists to JSON config file.

**Tech Stack:** MacroQuest Lua, ImGui for UI, mq.event for heal detection, mq.TLO for game data.

---

## File Structure

```
lua/
  deficithealer/
    init.lua           -- Main entry point, loop, binds
    config.lua         -- Configuration defaults and loading
    healtracker.lua    -- Tracks heal landing values
    targetmonitor.lua  -- Monitors HP/deficits for targets
    healselector.lua   -- Picks appropriate heal for situation
    proactive.lua      -- HoT and Promised heal logic
    analytics.lua      -- Performance tracking
    ui.lua             -- ImGui interface
    persistence.lua    -- Save/load data to file
```

---

## Task 1: Project Skeleton and Configuration

**Files:**
- Create: `src/plugins/lua/lua/deficithealer/init.lua`
- Create: `src/plugins/lua/lua/deficithealer/config.lua`

**Step 1: Create config module with defaults**

```lua
-- config.lua
local mq = require('mq')

local Config = {
    _version = '1.0',

    -- Thresholds
    emergencyPct = 25,              -- Below this = emergency heal
    groupHealMinCount = 3,          -- Min people for group heal
    groupHealMinDeficit = 15000,    -- Min deficit per person for group heal
    squishyMaxHP = 80000,           -- Below this max HP = squishy class

    -- Heal Selection
    squishyCoveragePct = 70,        -- Min deficit coverage for squishies
    overhealTolerancePct = 20,      -- Acceptable overheal

    -- HoT Behavior
    damageWindowSec = 6,            -- Seconds to track damage intake
    sustainedDamageThreshold = 5000, -- Min DPS before HoT considered

    -- Learning
    learningWeight = 0.1,           -- Weight for new heal data
    minSamplesForReliable = 10,     -- Samples before data is trusted

    -- Spells (user configures these)
    spells = {
        fast = {},      -- Fast single target (remedies)
        medium = {},    -- Medium single target
        large = {},     -- Large single target
        group = {},     -- Group heals
        hot = {},       -- Heal over time
        promised = {},  -- Promised heals
    },
}

function Config.Load(charName)
    local configPath = mq.configDir .. '/deficithealer_' .. charName .. '.lua'
    local f = io.open(configPath, 'r')
    if f then
        f:close()
        local saved = dofile(configPath)
        if saved then
            for k, v in pairs(saved) do
                if Config[k] ~= nil then
                    Config[k] = v
                end
            end
        end
    end
    return Config
end

function Config.Save(charName)
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

-- Helper to serialize tables
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

return Config
```

**Step 2: Create main init skeleton**

```lua
-- init.lua
local mq = require('mq')
local Config = require('deficithealer.config')

local DeficitHealer = {
    running = false,
    charName = mq.TLO.Me.Name(),
}

function DeficitHealer.Init()
    Config.Load(DeficitHealer.charName)
    print('[DeficitHealer] Loaded configuration for ' .. DeficitHealer.charName)
    DeficitHealer.running = true
end

function DeficitHealer.Shutdown()
    Config.Save(DeficitHealer.charName)
    DeficitHealer.running = false
    print('[DeficitHealer] Shutdown complete')
end

-- Binds
mq.bind('/deficithealer', function()
    if DeficitHealer.running then
        DeficitHealer.Shutdown()
    else
        DeficitHealer.Init()
    end
end)

mq.bind('/dh', function()
    if DeficitHealer.running then
        DeficitHealer.Shutdown()
    else
        DeficitHealer.Init()
    end
end)

-- Main loop placeholder
DeficitHealer.Init()

while DeficitHealer.running do
    mq.delay(100)
    mq.doevents()
end

DeficitHealer.Shutdown()
```

**Step 3: Test the skeleton loads**

Run in-game: `/lua run deficithealer`

Expected: See "[DeficitHealer] Loaded configuration for YourName" in chat.

**Step 4: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/
git commit -m "feat: add deficit healer skeleton with config"
```

---

## Task 2: Heal Tracker Module

**Files:**
- Create: `src/plugins/lua/lua/deficithealer/healtracker.lua`
- Modify: `src/plugins/lua/lua/deficithealer/init.lua`

**Step 1: Create heal tracker with weighted average**

```lua
-- healtracker.lua
local mq = require('mq')

local HealTracker = {
    heals = {},          -- spellName -> { avg, count, trend }
    recentHeals = {},    -- last N heals for trend calculation
    learningMode = true,
}

function HealTracker.Init(savedData, weight)
    HealTracker.weight = weight or 0.1
    if savedData then
        HealTracker.heals = savedData
        -- Check if we have enough data to exit learning mode
        local reliableCount = 0
        for _, data in pairs(HealTracker.heals) do
            if data.count >= 10 then
                reliableCount = reliableCount + 1
            end
        end
        HealTracker.learningMode = reliableCount < 3
    end
end

function HealTracker.RecordHeal(spellName, amount)
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
        local reliableCount = 0
        for _, data in pairs(HealTracker.heals) do
            if data.count >= 10 then
                reliableCount = reliableCount + 1
            end
        end
        HealTracker.learningMode = reliableCount < 3
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
```

**Step 2: Add event to capture heals landing**

Add to init.lua after requires:

```lua
local HealTracker = require('deficithealer.healtracker')

-- Event pattern for heal landing
-- Format: "You have been healed for X points by SpellName."
-- Format: "TargetName has been healed for X points by SpellName."
mq.event('HealLanded', '#1# ha#*#been healed for #2# point#*#by #3#.', function(target, amount, spell)
    -- Only track our heals
    local numAmount = tonumber(amount)
    if numAmount and spell then
        spell = spell:gsub('%.$', '') -- Remove trailing period
        HealTracker.RecordHeal(spell, numAmount)
    end
end)
```

**Step 3: Test heal tracking**

Run in-game: `/lua run deficithealer`, cast a heal, check if recorded.

Add debug output temporarily:
```lua
mq.event('HealLanded', '#1# ha#*#been healed for #2# point#*#by #3#.', function(target, amount, spell)
    local numAmount = tonumber(amount)
    if numAmount and spell then
        spell = spell:gsub('%.$', '')
        HealTracker.RecordHeal(spell, numAmount)
        print(string.format('[DeficitHealer] Tracked heal: %s for %d', spell, numAmount))
    end
end)
```

**Step 4: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/healtracker.lua
git add src/plugins/lua/lua/deficithealer/init.lua
git commit -m "feat: add heal tracker with weighted averaging"
```

---

## Task 3: Target Monitor Module

**Files:**
- Create: `src/plugins/lua/lua/deficithealer/targetmonitor.lua`
- Modify: `src/plugins/lua/lua/deficithealer/init.lua`

**Step 1: Create target monitor**

```lua
-- targetmonitor.lua
local mq = require('mq')

local TargetMonitor = {
    priorityTargets = {},   -- MT/MA from raid
    groupTargets = {},      -- Group members
    damageHistory = {},     -- target -> { timestamps, amounts }
}

function TargetMonitor.Init()
    TargetMonitor.priorityTargets = {}
    TargetMonitor.groupTargets = {}
    TargetMonitor.damageHistory = {}
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
                    spawn = member.Spawn,
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
            spawn = mq.TLO.Me,
            role = 'Self',
        })
    end
end

function TargetMonitor.GetTargetInfo(target)
    local spawn = target.spawn
    if not spawn or not spawn() then
        return nil
    end

    local currentHP = spawn.CurrentHPs() or 0
    local maxHP = spawn.MaxHPs() or 1
    local pctHP = spawn.PctHPs() or 100
    local deficit = maxHP - currentHP

    return {
        name = target.name,
        role = target.role,
        currentHP = currentHP,
        maxHP = maxHP,
        pctHP = pctHP,
        deficit = deficit,
        isSquishy = maxHP < 80000, -- Will use config value
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
```

**Step 2: Integrate into main loop**

Update init.lua main loop:

```lua
local TargetMonitor = require('deficithealer.targetmonitor')

-- In Init function:
TargetMonitor.Init()

-- In main loop:
while DeficitHealer.running do
    TargetMonitor.Update()

    -- Debug: print targets
    local targets = TargetMonitor.GetAllTargets()
    for _, t in ipairs(targets) do
        if t.deficit > 0 then
            print(string.format('[DH] %s (%s): %d/%d HP, deficit: %d',
                t.name, t.role, t.currentHP, t.maxHP, t.deficit))
        end
    end

    mq.delay(1000)
    mq.doevents()
end
```

**Step 3: Test target monitoring**

Run in-game in a group/raid, verify targets are detected and deficits calculated.

**Step 4: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/targetmonitor.lua
git add src/plugins/lua/lua/deficithealer/init.lua
git commit -m "feat: add target monitor for raid/group"
```

---

## Task 4: Heal Selector Module

**Files:**
- Create: `src/plugins/lua/lua/deficithealer/healselector.lua`
- Modify: `src/plugins/lua/lua/deficithealer/init.lua`

**Step 1: Create heal selector logic**

```lua
-- healselector.lua
local mq = require('mq')

local HealSelector = {
    config = nil,
    healTracker = nil,
    lastAction = nil,
}

function HealSelector.Init(config, healTracker)
    HealSelector.config = config
    HealSelector.healTracker = healTracker
end

-- Find best heal for a given target and deficit
function HealSelector.SelectHeal(targetInfo, situation)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local deficit = targetInfo.deficit

    if deficit <= 0 then return nil end

    -- Emergency: anyone below threshold gets fastest heal
    if targetInfo.pctHP < config.emergencyPct then
        return HealSelector.FindFastestHeal(deficit)
    end

    -- Squishy: prefer fast heals
    if targetInfo.isSquishy then
        return HealSelector.FindHealForSquishy(deficit)
    end

    -- Tank: can use slower, more efficient heals
    -- Unless multiple people need healing
    if situation.multipleHurt then
        return HealSelector.FindFastestHeal(deficit)
    end

    return HealSelector.FindEfficientHeal(deficit)
end

function HealSelector.FindFastestHeal(deficit)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    -- Try fast heals first
    for _, spellName in ipairs(config.spells.fast) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            return { spell = spellName, expected = expected, category = 'fast' }
        end
    end

    -- Fall back to medium
    for _, spellName in ipairs(config.spells.medium) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            return { spell = spellName, expected = expected, category = 'medium' }
        end
    end

    -- Last resort: large
    for _, spellName in ipairs(config.spells.large) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            return { spell = spellName, expected = expected, category = 'large' }
        end
    end

    -- Learning mode fallback: use first available spell
    if tracker.IsLearning() then
        if #config.spells.fast > 0 then
            return { spell = config.spells.fast[1], expected = 0, category = 'fast', learning = true }
        end
    end

    return nil
end

function HealSelector.FindHealForSquishy(deficit)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local minCoverage = deficit * (config.squishyCoveragePct / 100)

    -- Find smallest fast heal that covers minimum
    for _, spellName in ipairs(config.spells.fast) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected and expected >= minCoverage then
            return { spell = spellName, expected = expected, category = 'fast' }
        end
    end

    -- Try medium if fast doesn't cover
    for _, spellName in ipairs(config.spells.medium) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected and expected >= minCoverage then
            return { spell = spellName, expected = expected, category = 'medium' }
        end
    end

    -- Fall back to fastest available
    return HealSelector.FindFastestHeal(deficit)
end

function HealSelector.FindEfficientHeal(deficit)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker
    local maxOverheal = deficit * (1 + config.overhealTolerancePct / 100)

    local bestHeal = nil
    local bestMatch = math.huge

    -- Check all heal categories for best match
    local allSpells = {}
    for _, s in ipairs(config.spells.fast) do table.insert(allSpells, {name = s, cat = 'fast'}) end
    for _, s in ipairs(config.spells.medium) do table.insert(allSpells, {name = s, cat = 'medium'}) end
    for _, s in ipairs(config.spells.large) do table.insert(allSpells, {name = s, cat = 'large'}) end

    for _, spell in ipairs(allSpells) do
        local expected = tracker.GetExpectedHeal(spell.name)
        if expected then
            -- Skip if too much overheal
            if expected <= maxOverheal then
                -- Find closest match to deficit
                local diff = math.abs(expected - deficit)
                if diff < bestMatch then
                    bestMatch = diff
                    bestHeal = { spell = spell.name, expected = expected, category = spell.cat }
                end
            end
        end
    end

    -- If no good match, use smallest that covers
    if not bestHeal then
        for _, spell in ipairs(allSpells) do
            local expected = tracker.GetExpectedHeal(spell.name)
            if expected and expected >= deficit then
                return { spell = spell.name, expected = expected, category = spell.cat }
            end
        end
    end

    return bestHeal or HealSelector.FindFastestHeal(deficit)
end

function HealSelector.ShouldUseGroupHeal(targets)
    local config = HealSelector.config
    local tracker = HealSelector.healTracker

    -- Count people with significant deficit
    local hurtCount = 0
    local totalDeficit = 0
    local hasEmergency = false

    for _, t in ipairs(targets) do
        if t.pctHP < config.emergencyPct then
            hasEmergency = true
        end
        if t.deficit >= config.groupHealMinDeficit then
            hurtCount = hurtCount + 1
            totalDeficit = totalDeficit + t.deficit
        end
    end

    -- Don't use group heal if someone is in emergency
    if hasEmergency then
        return false, nil
    end

    -- Check if we meet count threshold
    if hurtCount < config.groupHealMinCount then
        return false, nil
    end

    -- Check if group heal is efficient
    for _, spellName in ipairs(config.spells.group) do
        local expected = tracker.GetExpectedHeal(spellName)
        if expected then
            local totalHealing = expected * hurtCount
            if totalHealing >= totalDeficit * 0.7 then -- 70% efficiency threshold
                return true, { spell = spellName, expected = expected, targets = hurtCount }
            end
        end
    end

    return false, nil
end

function HealSelector.GetLastAction()
    return HealSelector.lastAction
end

function HealSelector.SetLastAction(action)
    HealSelector.lastAction = action
end

return HealSelector
```

**Step 2: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/healselector.lua
git commit -m "feat: add heal selector with deficit-based logic"
```

---

## Task 5: Proactive Heals Module (HoTs & Promised)

**Files:**
- Create: `src/plugins/lua/lua/deficithealer/proactive.lua`

**Step 1: Create proactive heal manager**

```lua
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
```

**Step 2: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/proactive.lua
git commit -m "feat: add proactive heal manager for HoTs and Promised"
```

---

## Task 6: Analytics Module

**Files:**
- Create: `src/plugins/lua/lua/deficithealer/analytics.lua`

**Step 1: Create analytics tracker**

```lua
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
        reactionTimes = {},  -- deficit severity -> times
    },
    history = {},  -- previous sessions
}

function Analytics.Init()
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
end

function Analytics.RecordHeal(spellName, healAmount, deficit, targetName)
    local session = Analytics.session
    session.healsCount = session.healsCount + 1

    local effective = math.min(healAmount, deficit)
    local overheal = math.max(0, healAmount - deficit)

    session.totalHealing = session.totalHealing + effective
    session.totalOverheal = session.totalOverheal + overheal
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
    local session = Analytics.session
    local category
    if deficitPct < 20 then
        category = 'small'
    elseif deficitPct < 50 then
        category = 'medium'
    else
        category = 'large'
    end

    table.insert(session.reactionTimes[category], reactionMs)

    -- Keep only last 50 per category
    while #session.reactionTimes[category] > 50 do
        table.remove(session.reactionTimes[category], 1)
    end
end

function Analytics.GetOverhealPct()
    local session = Analytics.session
    local total = session.totalHealing + session.totalOverheal
    if total == 0 then return 0 end
    return (session.totalOverheal / total) * 100
end

function Analytics.GetEfficiency()
    local session = Analytics.session
    local total = session.totalHealing + session.totalOverheal
    if total == 0 then return 100 end
    return (session.totalHealing / total) * 100
end

function Analytics.GetAverageReactionTime(category)
    local times = Analytics.session.reactionTimes[category]
    if not times or #times == 0 then return 0 end

    local sum = 0
    for _, t in ipairs(times) do
        sum = sum + t
    end
    return sum / #times
end

function Analytics.GetSessionStats()
    local session = Analytics.session
    local duration = os.time() - session.startTime

    return {
        duration = duration,
        healsCount = session.healsCount,
        totalHealing = session.totalHealing,
        totalOverheal = session.totalOverheal,
        efficiency = Analytics.GetEfficiency(),
        overhealPct = Analytics.GetOverhealPct(),
        criticalEvents = session.criticalEvents,
        nearMisses = session.nearMisses,
        deaths = session.deaths,
        avgReactionSmall = Analytics.GetAverageReactionTime('small'),
        avgReactionMedium = Analytics.GetAverageReactionTime('medium'),
        avgReactionLarge = Analytics.GetAverageReactionTime('large'),
    }
end

function Analytics.SaveSession()
    table.insert(Analytics.history, Analytics.GetSessionStats())
    -- Keep only last 10 sessions
    while #Analytics.history > 10 do
        table.remove(Analytics.history, 1)
    end
end

function Analytics.GetHistory()
    return Analytics.history
end

return Analytics
```

**Step 2: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/analytics.lua
git commit -m "feat: add analytics module for performance tracking"
```

---

## Task 7: User Interface

**Files:**
- Create: `src/plugins/lua/lua/deficithealer/ui.lua`
- Modify: `src/plugins/lua/lua/deficithealer/init.lua`

**Step 1: Create UI module**

```lua
-- ui.lua
local mq = require('mq')
require 'ImGui'

local UI = {
    open = true,
    compact = false,
    currentTab = 'status',
}

local modules = {}

function UI.Init(config, healTracker, targetMonitor, healselector, analytics)
    modules.config = config
    modules.healTracker = healTracker
    modules.targetMonitor = targetMonitor
    modules.healselector = healselector
    modules.analytics = analytics
end

function UI.DrawStatusTab()
    local targets = modules.targetMonitor.GetAllTargets()

    -- Mode indicator
    if modules.healTracker.IsLearning() then
        ImGui.TextColored(1, 1, 0, 1, 'Mode: LEARNING')
    else
        ImGui.TextColored(0, 1, 0, 1, 'Mode: Normal')
    end

    ImGui.Separator()
    ImGui.Text('Targets:')

    -- Target list with HP bars
    for _, t in ipairs(targets) do
        local hpRatio = t.pctHP / 100
        local r, g = 1 - hpRatio, hpRatio

        ImGui.PushStyleColor(ImGuiCol.PlotHistogram, r, g, 0, 1)
        ImGui.ProgressBar(hpRatio, 200, 0,
            string.format('%s (%s): %d%%', t.name, t.role, t.pctHP))
        ImGui.PopStyleColor()

        if t.deficit > 0 then
            ImGui.SameLine()
            ImGui.Text(string.format('Deficit: %dk', t.deficit / 1000))
        end
    end

    ImGui.Separator()

    -- Last action
    local lastAction = modules.healselector.GetLastAction()
    if lastAction then
        ImGui.Text('Last Action: ' .. lastAction)
    end
end

function UI.DrawHealDataTab()
    ImGui.Text('Tracked Heal Values:')
    ImGui.Separator()

    local data = modules.healTracker.GetAllData()

    if ImGui.BeginTable('HealData', 5, ImGuiTableFlags.Borders) then
        ImGui.TableSetupColumn('Spell')
        ImGui.TableSetupColumn('Avg')
        ImGui.TableSetupColumn('Count')
        ImGui.TableSetupColumn('Min')
        ImGui.TableSetupColumn('Max')
        ImGui.TableHeadersRow()

        for spell, info in pairs(data) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text(spell)
            ImGui.TableNextColumn()
            ImGui.Text(string.format('%dk', info.avg / 1000))
            ImGui.TableNextColumn()
            ImGui.Text(tostring(info.count))
            ImGui.TableNextColumn()
            ImGui.Text(string.format('%dk', info.min / 1000))
            ImGui.TableNextColumn()
            ImGui.Text(string.format('%dk', info.max / 1000))
        end

        ImGui.EndTable()
    end

    if ImGui.Button('Reset All Data') then
        -- TODO: Implement reset
    end
end

function UI.DrawAnalyticsTab()
    local stats = modules.analytics.GetSessionStats()

    ImGui.Text('Session Statistics')
    ImGui.Separator()

    -- Duration
    local mins = math.floor(stats.duration / 60)
    local secs = stats.duration % 60
    ImGui.Text(string.format('Duration: %d:%02d', mins, secs))

    ImGui.Spacing()

    -- Efficiency section
    ImGui.Text('Efficiency:')
    ImGui.Text(string.format('  Heals Cast: %d', stats.healsCount))
    ImGui.Text(string.format('  Total Healing: %dk', stats.totalHealing / 1000))
    ImGui.Text(string.format('  Overheal: %dk (%.1f%%)', stats.totalOverheal / 1000, stats.overhealPct))

    -- Efficiency bar
    local effRatio = stats.efficiency / 100
    ImGui.PushStyleColor(ImGuiCol.PlotHistogram, 0, effRatio, 0, 1)
    ImGui.ProgressBar(effRatio, -1, 0, string.format('Efficiency: %.1f%%', stats.efficiency))
    ImGui.PopStyleColor()

    ImGui.Spacing()

    -- Safety section
    ImGui.Text('Safety:')

    local safetyColor = stats.deaths > 0 and {1, 0, 0, 1} or
                        stats.criticalEvents > 2 and {1, 1, 0, 1} or
                        {0, 1, 0, 1}

    ImGui.TextColored(safetyColor[1], safetyColor[2], safetyColor[3], safetyColor[4],
        string.format('  Deaths: %d | Criticals: %d | Near-misses: %d',
            stats.deaths, stats.criticalEvents, stats.nearMisses))

    ImGui.Spacing()

    -- Response times
    ImGui.Text('Avg Response Time:')
    ImGui.Text(string.format('  Small deficit: %.0fms', stats.avgReactionSmall))
    ImGui.Text(string.format('  Medium deficit: %.0fms', stats.avgReactionMedium))
    ImGui.Text(string.format('  Large deficit: %.0fms', stats.avgReactionLarge))
end

function UI.DrawConfigTab()
    local config = modules.config
    local changed = false

    ImGui.Text('Thresholds')
    ImGui.Separator()

    local newVal

    newVal = ImGui.SliderInt('Emergency HP %', config.emergencyPct, 10, 50)
    if newVal ~= config.emergencyPct then
        config.emergencyPct = newVal
        changed = true
    end

    newVal = ImGui.SliderInt('Group Heal Min Count', config.groupHealMinCount, 2, 5)
    if newVal ~= config.groupHealMinCount then
        config.groupHealMinCount = newVal
        changed = true
    end

    newVal = ImGui.SliderInt('Group Heal Min Deficit (k)', config.groupHealMinDeficit / 1000, 5, 50)
    if newVal ~= config.groupHealMinDeficit / 1000 then
        config.groupHealMinDeficit = newVal * 1000
        changed = true
    end

    newVal = ImGui.SliderInt('Squishy Max HP (k)', config.squishyMaxHP / 1000, 30, 150)
    if newVal ~= config.squishyMaxHP / 1000 then
        config.squishyMaxHP = newVal * 1000
        changed = true
    end

    ImGui.Spacing()
    ImGui.Text('Heal Selection')
    ImGui.Separator()

    newVal = ImGui.SliderInt('Squishy Coverage %', config.squishyCoveragePct, 50, 100)
    if newVal ~= config.squishyCoveragePct then
        config.squishyCoveragePct = newVal
        changed = true
    end

    newVal = ImGui.SliderInt('Overheal Tolerance %', config.overhealTolerancePct, 0, 50)
    if newVal ~= config.overhealTolerancePct then
        config.overhealTolerancePct = newVal
        changed = true
    end

    ImGui.Spacing()

    if changed and ImGui.Button('Save Config') then
        config.Save(mq.TLO.Me.Name())
    end
end

function UI.DrawCompact()
    local targets = modules.targetMonitor.GetPriorityTargets()

    -- Mode indicator
    if modules.healTracker.IsLearning() then
        ImGui.TextColored(1, 1, 0, 1, '[LEARNING]')
    end

    -- Priority targets only
    for _, t in ipairs(targets) do
        local hpRatio = t.pctHP / 100
        local r, g = 1 - hpRatio, hpRatio
        ImGui.PushStyleColor(ImGuiCol.PlotHistogram, r, g, 0, 1)
        ImGui.ProgressBar(hpRatio, 150, 0, string.format('%s: %d%%', t.name, t.pctHP))
        ImGui.PopStyleColor()
    end
end

function UI.Draw()
    if not UI.open then return end

    UI.open = ImGui.Begin('Deficit Healer', UI.open)

    -- Compact toggle
    if ImGui.Button(UI.compact and 'Expand' or 'Compact') then
        UI.compact = not UI.compact
    end

    if UI.compact then
        UI.DrawCompact()
    else
        if ImGui.BeginTabBar('MainTabs') then
            if ImGui.BeginTabItem('Status') then
                UI.DrawStatusTab()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Heal Data') then
                UI.DrawHealDataTab()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Analytics') then
                UI.DrawAnalyticsTab()
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Config') then
                UI.DrawConfigTab()
                ImGui.EndTabItem()
            end
            ImGui.EndTabBar()
        end
    end

    ImGui.End()
end

function UI.Toggle()
    UI.open = not UI.open
end

function UI.IsOpen()
    return UI.open
end

return UI
```

**Step 2: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/ui.lua
git commit -m "feat: add ImGui UI with status, data, analytics, config tabs"
```

---

## Task 8: Data Persistence

**Files:**
- Create: `src/plugins/lua/lua/deficithealer/persistence.lua`

**Step 1: Create persistence module**

```lua
-- persistence.lua
local mq = require('mq')

local Persistence = {}

local function serializeValue(val, indent)
    indent = indent or ''
    local valType = type(val)

    if valType == 'nil' then
        return 'nil'
    elseif valType == 'boolean' then
        return tostring(val)
    elseif valType == 'number' then
        return tostring(val)
    elseif valType == 'string' then
        return string.format('%q', val)
    elseif valType == 'table' then
        local parts = {}
        local nextIndent = indent .. '  '
        table.insert(parts, '{\n')
        for k, v in pairs(val) do
            local keyStr
            if type(k) == 'string' then
                keyStr = k
            else
                keyStr = '[' .. tostring(k) .. ']'
            end
            table.insert(parts, nextIndent .. keyStr .. ' = ' .. serializeValue(v, nextIndent) .. ',\n')
        end
        table.insert(parts, indent .. '}')
        return table.concat(parts)
    else
        return 'nil -- unsupported type: ' .. valType
    end
end

function Persistence.Save(charName, healData, analyticsHistory)
    local configDir = mq.configDir
    local path = configDir .. '/deficithealer_' .. charName .. '_data.lua'

    local data = {
        healData = healData,
        analyticsHistory = analyticsHistory,
        savedAt = os.time(),
    }

    local content = 'return ' .. serializeValue(data)

    local f = io.open(path, 'w')
    if f then
        f:write(content)
        f:close()
        return true
    end
    return false
end

function Persistence.Load(charName)
    local configDir = mq.configDir
    local path = configDir .. '/deficithealer_' .. charName .. '_data.lua'

    local f = io.open(path, 'r')
    if f then
        f:close()
        local ok, data = pcall(dofile, path)
        if ok and data then
            return data.healData, data.analyticsHistory
        end
    end
    return nil, nil
end

function Persistence.Exists(charName)
    local configDir = mq.configDir
    local path = configDir .. '/deficithealer_' .. charName .. '_data.lua'
    local f = io.open(path, 'r')
    if f then
        f:close()
        return true
    end
    return false
end

function Persistence.Delete(charName)
    local configDir = mq.configDir
    local path = configDir .. '/deficithealer_' .. charName .. '_data.lua'
    os.remove(path)
end

return Persistence
```

**Step 2: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/persistence.lua
git commit -m "feat: add data persistence for heal values and analytics"
```

---

## Task 9: Main Loop Integration

**Files:**
- Modify: `src/plugins/lua/lua/deficithealer/init.lua`

**Step 1: Complete main loop with all modules**

```lua
-- init.lua (complete version)
local mq = require('mq')
require 'ImGui'

local Config = require('deficithealer.config')
local HealTracker = require('deficithealer.healtracker')
local TargetMonitor = require('deficithealer.targetmonitor')
local HealSelector = require('deficithealer.healselector')
local Proactive = require('deficithealer.proactive')
local Analytics = require('deficithealer.analytics')
local UI = require('deficithealer.ui')
local Persistence = require('deficithealer.persistence')

local DeficitHealer = {
    running = false,
    charName = mq.TLO.Me.Name(),
    casting = false,
}

-- Heal landed event
mq.event('HealLanded', '#1# ha#*#been healed for #2# point#*#by #3#.', function(target, amount, spell)
    local numAmount = tonumber(amount)
    if numAmount and spell then
        spell = spell:gsub('%.$', '')
        HealTracker.RecordHeal(spell, numAmount)
    end
end)

function DeficitHealer.Init()
    DeficitHealer.charName = mq.TLO.Me.Name()

    -- Load saved data
    local healData, analyticsHistory = Persistence.Load(DeficitHealer.charName)

    -- Initialize modules
    Config.Load(DeficitHealer.charName)
    HealTracker.Init(healData, Config.learningWeight)
    TargetMonitor.Init()
    HealSelector.Init(Config, HealTracker)
    Proactive.Init(Config, HealTracker, TargetMonitor)
    Analytics.Init()
    UI.Init(Config, HealTracker, TargetMonitor, HealSelector, Analytics)

    if analyticsHistory then
        -- Restore analytics history
    end

    DeficitHealer.running = true
    print('[DeficitHealer] Initialized for ' .. DeficitHealer.charName)
end

function DeficitHealer.Shutdown()
    -- Save data
    Persistence.Save(DeficitHealer.charName, HealTracker.GetData(), Analytics.GetHistory())
    Analytics.SaveSession()
    Config.Save(DeficitHealer.charName)

    DeficitHealer.running = false
    print('[DeficitHealer] Shutdown complete - data saved')
end

function DeficitHealer.CastHeal(spellName, targetName)
    if DeficitHealer.casting then return false end

    -- Target and cast
    mq.cmdf('/target %s', targetName)
    mq.delay(100)
    mq.cmdf('/cast "%s"', spellName)

    DeficitHealer.casting = true
    HealSelector.SetLastAction(string.format('Casting %s on %s', spellName, targetName))

    return true
end

function DeficitHealer.ProcessHealing()
    -- Update targets
    TargetMonitor.Update()
    Proactive.Update()

    -- Check if we're already casting
    if mq.TLO.Me.Casting() then
        DeficitHealer.casting = true
        return
    else
        DeficitHealer.casting = false
    end

    local allTargets = TargetMonitor.GetAllTargets()
    local priorityTargets = TargetMonitor.GetPriorityTargets()
    local groupTargets = TargetMonitor.GetGroupTargets()

    -- Build situation context
    local situation = {
        hasEmergency = false,
        multipleHurt = 0,
    }

    for _, t in ipairs(allTargets) do
        if t.pctHP < Config.emergencyPct then
            situation.hasEmergency = true
        end
        if t.deficit > 0 then
            situation.multipleHurt = situation.multipleHurt + 1
        end
    end
    situation.multipleHurt = situation.multipleHurt > 1

    -- Priority 1: Emergency heals
    for _, t in ipairs(allTargets) do
        if t.pctHP < Config.emergencyPct then
            local heal = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name)
                Analytics.RecordCriticalEvent(t.name, t.pctHP)
                return
            end
        end
    end

    -- Priority 2: Group heal check
    local useGroup, groupHeal = HealSelector.ShouldUseGroupHeal(allTargets)
    if useGroup and groupHeal then
        DeficitHealer.CastHeal(groupHeal.spell, mq.TLO.Me.Name())
        return
    end

    -- Priority 3: Priority targets (MT/MA)
    for _, t in ipairs(priorityTargets) do
        if t.deficit > 0 then
            local heal = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name)
                return
            end
        end
    end

    -- Priority 4: Group targets
    for _, t in ipairs(groupTargets) do
        if t.deficit > 0 then
            local heal = HealSelector.SelectHeal(t, situation)
            if heal then
                DeficitHealer.CastHeal(heal.spell, t.name)
                return
            end
        end
    end

    -- Priority 5: Proactive heals (if stable)
    if not situation.hasEmergency then
        for _, t in ipairs(priorityTargets) do
            local shouldHot, hotSpell = Proactive.ShouldApplyHot(t)
            if shouldHot then
                DeficitHealer.CastHeal(hotSpell, t.name)
                Proactive.RecordHot(t.name, hotSpell, 18) -- Assume 18s duration
                return
            end

            local shouldPromised, promisedSpell = Proactive.ShouldApplyPromised(t, situation)
            if shouldPromised then
                DeficitHealer.CastHeal(promisedSpell, t.name)
                Proactive.RecordPromised(t.name, promisedSpell, 18)
                return
            end
        end
    end
end

-- ImGui registration
mq.imgui.init('DeficitHealerUI', function()
    UI.Draw()
end)

-- Binds
mq.bind('/deficithealer', function()
    if DeficitHealer.running then
        DeficitHealer.Shutdown()
    else
        DeficitHealer.Init()
    end
end)

mq.bind('/dh', function()
    if DeficitHealer.running then
        DeficitHealer.Shutdown()
    else
        DeficitHealer.Init()
    end
end)

mq.bind('/dhui', function()
    UI.Toggle()
end)

-- Initialize and run
DeficitHealer.Init()

while DeficitHealer.running do
    DeficitHealer.ProcessHealing()
    mq.delay(100) -- 100ms loop
    mq.doevents()
end

DeficitHealer.Shutdown()
```

**Step 2: Test full integration**

Run in-game: `/lua run deficithealer`

Verify:
- UI appears
- Targets are tracked
- Heal data tab shows any heals cast
- Config changes save

**Step 3: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/init.lua
git commit -m "feat: complete main loop integration with all modules"
```

---

## Task 10: Spell Configuration Helper

**Files:**
- Modify: `src/plugins/lua/lua/deficithealer/ui.lua`

**Step 1: Add spell configuration to Config tab**

Add to UI.DrawConfigTab():

```lua
ImGui.Spacing()
ImGui.Text('Spell Configuration')
ImGui.Separator()

-- Show current spells
for category, spells in pairs(config.spells) do
    if ImGui.TreeNode(category:upper()) then
        for i, spell in ipairs(spells) do
            ImGui.Text(string.format('%d. %s', i, spell))
            ImGui.SameLine()
            if ImGui.SmallButton('Remove##' .. category .. i) then
                table.remove(config.spells[category], i)
            end
        end

        -- Add new spell
        ImGui.Text('Add from spell gems:')
        for gem = 1, 13 do
            local spellName = mq.TLO.Me.Gem(gem).Name()
            if spellName and spellName ~= '' then
                if ImGui.SmallButton(spellName .. '##' .. category) then
                    table.insert(config.spells[category], spellName)
                end
            end
        end

        ImGui.TreePop()
    end
end
```

**Step 2: Commit**

```bash
git add src/plugins/lua/lua/deficithealer/ui.lua
git commit -m "feat: add spell configuration UI with gem picker"
```

---

## Task 11: Final Testing and Polish

**Files:**
- All files in `src/plugins/lua/lua/deficithealer/`

**Step 1: Add error handling**

Review each module for nil checks and error handling.

**Step 2: Test scenarios**

Manual test checklist:
- [ ] Script loads without errors
- [ ] UI opens and displays correctly
- [ ] Targets are detected in group
- [ ] Targets are detected in raid (MT/MA)
- [ ] Heals landing are tracked and averaged
- [ ] Casting heals on targets works
- [ ] Configuration saves and loads
- [ ] Analytics update during session
- [ ] Data persists between sessions

**Step 3: Final commit**

```bash
git add src/plugins/lua/lua/deficithealer/
git commit -m "feat: deficit-based healer complete with learning and analytics"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Project skeleton and config | init.lua, config.lua |
| 2 | Heal tracker with weighted average | healtracker.lua |
| 3 | Target monitor for raid/group | targetmonitor.lua |
| 4 | Heal selector with deficit logic | healselector.lua |
| 5 | Proactive heals (HoTs/Promised) | proactive.lua |
| 6 | Analytics module | analytics.lua |
| 7 | ImGui UI | ui.lua |
| 8 | Data persistence | persistence.lua |
| 9 | Main loop integration | init.lua |
| 10 | Spell configuration helper | ui.lua |
| 11 | Testing and polish | all files |
