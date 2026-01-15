-- persistence.lua
-- Data Persistence Module for Deficit-Based Healer
-- Saves and loads heal data and analytics history to files

local mq = require('mq')

local Persistence = {}

-- Helper to serialize Lua values to string
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
        return string.format('%q', val)  -- Properly quoted string
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

--- Save heal data and analytics history to a file
---@param charName string Character name to save data for
---@param healData table|nil Heal data to persist
---@param analyticsHistory table|nil Analytics history to persist
---@return boolean success True if save was successful
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

--- Load heal data and analytics history from a file
---@param charName string Character name to load data for
---@return table|nil healData Loaded heal data or nil if not found/corrupt
---@return table|nil analyticsHistory Loaded analytics history or nil if not found/corrupt
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

--- Check if persistence data exists for a character
---@param charName string Character name to check
---@return boolean exists True if data file exists
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

--- Delete persistence data for a character
---@param charName string Character name to delete data for
function Persistence.Delete(charName)
    local configDir = mq.configDir
    local path = configDir .. '/deficithealer_' .. charName .. '_data.lua'
    os.remove(path)
end

return Persistence
