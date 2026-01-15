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
                    Config[k] = v
                end
            end
        end
    end
    return Config
end

function Config.Save(charName)
    if not charName or charName == '' then
        return false
    end

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

return Config
