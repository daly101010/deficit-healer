-- ui.lua
require 'ImGui'
local mq = require('mq')

local UI = {
    open = true,
    compact = false,
    currentTab = 'status',
}

local modules = {}

-- Helper function to format numbers in 'k' format
local function formatK(value)
    if not value or value == 0 then
        return '0'
    end
    if value >= 1000 then
        return string.format('%.1fk', value / 1000)
    end
    return tostring(math.floor(value))
end

-- Helper function to format duration as MM:SS
local function formatDuration(seconds)
    if not seconds then return '00:00' end
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format('%02d:%02d', mins, secs)
end

-- Helper to get HP bar color (red when low, yellow mid, green when full)
local function getHPColor(pctHP)
    pctHP = pctHP or 100
    if pctHP <= 25 then
        return 0.9, 0.1, 0.1, 1.0  -- Red
    elseif pctHP <= 50 then
        return 0.9, 0.5, 0.1, 1.0  -- Orange
    elseif pctHP <= 75 then
        return 0.9, 0.9, 0.1, 1.0  -- Yellow
    else
        return 0.1, 0.9, 0.1, 1.0  -- Green
    end
end

function UI.Init(config, healTracker, targetMonitor, healselector, analytics)
    modules.config = config
    modules.healTracker = healTracker
    modules.targetMonitor = targetMonitor
    modules.healselector = healselector
    modules.analytics = analytics
end

function UI.DrawStatusTab()
    -- Learning mode indicator
    local isLearning = modules.healTracker and modules.healTracker.IsLearning()
    if isLearning then
        ImGui.TextColored(1.0, 0.9, 0.1, 1.0, 'Mode: LEARNING')
        ImGui.SameLine()
        ImGui.TextDisabled('(Collecting heal data...)')
    else
        ImGui.TextColored(0.1, 0.9, 0.1, 1.0, 'Mode: Normal')
    end

    ImGui.Separator()

    -- Last action display
    local lastAction = modules.healselector and modules.healselector.GetLastAction()
    if lastAction then
        ImGui.Text('Last Action:')
        ImGui.SameLine()
        -- Handle both string (legacy) and table formats
        if type(lastAction) == 'string' then
            ImGui.TextColored(0.5, 0.8, 1.0, 1.0, lastAction)
        else
            ImGui.TextColored(0.5, 0.8, 1.0, 1.0, string.format('%s on %s (%s)',
                lastAction.spell or 'Unknown',
                lastAction.target or 'Unknown',
                formatK(lastAction.expected or 0)))
        end
    else
        ImGui.TextDisabled('Last Action: None')
    end

    ImGui.Separator()
    ImGui.Text('Targets:')

    -- Get all targets
    local targets = modules.targetMonitor and modules.targetMonitor.GetAllTargets() or {}

    if #targets == 0 then
        ImGui.TextDisabled('No targets tracked')
        return
    end

    -- Display targets with HP bars
    for _, target in ipairs(targets) do
        local pctHP = target.pctHP or 100
        local r, g, b, a = getHPColor(pctHP)

        -- Role indicator
        local roleColor
        if target.role == 'MT' or target.role == 'MA' then
            roleColor = {1.0, 0.8, 0.2, 1.0}  -- Gold for priority
        elseif target.role == 'Self' then
            roleColor = {0.5, 0.8, 1.0, 1.0}  -- Blue for self
        else
            roleColor = {0.8, 0.8, 0.8, 1.0}  -- Gray for group
        end

        ImGui.TextColored(roleColor[1], roleColor[2], roleColor[3], roleColor[4],
            string.format('[%s]', target.role or 'Grp'))
        ImGui.SameLine()
        ImGui.Text(target.name or 'Unknown')
        ImGui.SameLine()

        -- HP bar
        ImGui.PushStyleColor(ImGuiCol.PlotHistogram, r, g, b, a)
        ImGui.ProgressBar(pctHP / 100, 150, 14, string.format('%d%%', pctHP))
        ImGui.PopStyleColor()

        ImGui.SameLine()
        if target.deficit and target.deficit > 0 then
            ImGui.TextColored(1.0, 0.5, 0.5, 1.0, string.format('Deficit: %s', formatK(target.deficit)))
        else
            ImGui.TextColored(0.5, 0.8, 0.5, 1.0, 'Full')
        end
    end
end

function UI.DrawHealDataTab()
    local healData = modules.healTracker and modules.healTracker.GetAllData() or {}

    -- Count entries
    local count = 0
    for _ in pairs(healData) do count = count + 1 end

    if count == 0 then
        ImGui.TextDisabled('No heal data tracked yet.')
        ImGui.TextDisabled('Cast some heals to start learning!')
        return
    end

    ImGui.Text(string.format('Tracked Spells: %d', count))
    ImGui.Separator()

    -- Heal data table
    if ImGui.BeginTable('HealDataTable', 5, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
        ImGui.TableSetupColumn('Spell')
        ImGui.TableSetupColumn('Avg')
        ImGui.TableSetupColumn('Count')
        ImGui.TableSetupColumn('Min')
        ImGui.TableSetupColumn('Max')
        ImGui.TableHeadersRow()

        for spellName, data in pairs(healData) do
            ImGui.TableNextRow()

            ImGui.TableNextColumn()
            ImGui.Text(spellName)

            ImGui.TableNextColumn()
            ImGui.Text(formatK(data.avg))

            ImGui.TableNextColumn()
            -- Color code count based on reliability
            if data.count >= 10 then
                ImGui.TextColored(0.1, 0.9, 0.1, 1.0, tostring(data.count))
            elseif data.count >= 3 then
                ImGui.TextColored(0.9, 0.9, 0.1, 1.0, tostring(data.count))
            else
                ImGui.TextColored(0.9, 0.5, 0.1, 1.0, tostring(data.count))
            end

            ImGui.TableNextColumn()
            ImGui.Text(formatK(data.min))

            ImGui.TableNextColumn()
            ImGui.Text(formatK(data.max))
        end

        ImGui.EndTable()
    end

    ImGui.Separator()

    -- Reset Data button (TODO placeholder)
    if ImGui.Button('Reset Data (TODO)') then
        -- TODO: Implement data reset functionality
    end
    ImGui.SameLine()
    ImGui.TextDisabled('Clears all learned heal values')
end

function UI.DrawAnalyticsTab()
    local stats = modules.analytics and modules.analytics.GetSessionStats() or {}

    -- Duration
    ImGui.Text('Session Duration:')
    ImGui.SameLine()
    ImGui.TextColored(0.5, 0.8, 1.0, 1.0, formatDuration(stats.duration))

    ImGui.Separator()

    -- Two-column layout for stats
    if ImGui.BeginTable('AnalyticsTable', 2, ImGuiTableFlags.None) then
        -- Heals Cast
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Heals Cast:')
        ImGui.TableNextColumn()
        ImGui.Text(tostring(stats.healsCount or 0))

        -- Total Healing
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Total Healing:')
        ImGui.TableNextColumn()
        ImGui.Text(formatK(stats.totalHealing or 0))

        -- Overheal
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Overheal:')
        ImGui.TableNextColumn()
        local overhealPct = stats.overhealPct or 0
        if overhealPct > 30 then
            ImGui.TextColored(0.9, 0.3, 0.3, 1.0, string.format('%s (%.1f%%)', formatK(stats.totalOverheal or 0), overhealPct))
        elseif overhealPct > 15 then
            ImGui.TextColored(0.9, 0.9, 0.3, 1.0, string.format('%s (%.1f%%)', formatK(stats.totalOverheal or 0), overhealPct))
        else
            ImGui.TextColored(0.3, 0.9, 0.3, 1.0, string.format('%s (%.1f%%)', formatK(stats.totalOverheal or 0), overhealPct))
        end

        ImGui.EndTable()
    end

    -- Efficiency bar
    ImGui.Separator()
    ImGui.Text('Efficiency:')
    local efficiency = (stats.efficiency or 100) / 100
    local effR, effG, effB = 0.3, 0.9, 0.3
    if efficiency < 0.7 then
        effR, effG, effB = 0.9, 0.3, 0.3
    elseif efficiency < 0.85 then
        effR, effG, effB = 0.9, 0.9, 0.3
    end
    ImGui.PushStyleColor(ImGuiCol.PlotHistogram, effR, effG, effB, 1.0)
    ImGui.ProgressBar(efficiency, -1, 20, string.format('%.1f%%', (stats.efficiency or 100)))
    ImGui.PopStyleColor()

    ImGui.Separator()

    -- Critical events section
    ImGui.Text('Events:')
    if ImGui.BeginTable('EventsTable', 2, ImGuiTableFlags.None) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Deaths:')
        ImGui.TableNextColumn()
        local deaths = stats.deaths or 0
        if deaths > 0 then
            ImGui.TextColored(0.9, 0.1, 0.1, 1.0, tostring(deaths))
        else
            ImGui.TextColored(0.3, 0.9, 0.3, 1.0, '0')
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Critical Events:')
        ImGui.TableNextColumn()
        local critEvents = stats.criticalEvents or 0
        if critEvents > 0 then
            ImGui.TextColored(0.9, 0.5, 0.1, 1.0, tostring(critEvents))
        else
            ImGui.Text('0')
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Near Misses:')
        ImGui.TableNextColumn()
        local nearMisses = stats.nearMisses or 0
        if nearMisses > 0 then
            ImGui.TextColored(0.9, 0.9, 0.1, 1.0, tostring(nearMisses))
        else
            ImGui.Text('0')
        end

        ImGui.EndTable()
    end

    ImGui.Separator()

    -- Reaction times
    ImGui.Text('Avg Reaction Times:')
    if ImGui.BeginTable('ReactionTable', 2, ImGuiTableFlags.None) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Small Deficit (<20%):')
        ImGui.TableNextColumn()
        local rtSmall = stats.avgReactionSmall
        ImGui.Text(rtSmall and string.format('%.0f ms', rtSmall) or 'N/A')

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Medium Deficit (20-50%):')
        ImGui.TableNextColumn()
        local rtMedium = stats.avgReactionMedium
        ImGui.Text(rtMedium and string.format('%.0f ms', rtMedium) or 'N/A')

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text('Large Deficit (>50%):')
        ImGui.TableNextColumn()
        local rtLarge = stats.avgReactionLarge
        ImGui.Text(rtLarge and string.format('%.0f ms', rtLarge) or 'N/A')

        ImGui.EndTable()
    end

    -- Heals per minute
    ImGui.Separator()
    ImGui.Text(string.format('Heals/Min: %.1f', stats.healsPerMinute or 0))
end

function UI.DrawConfigTab()
    if not modules.config then
        ImGui.TextDisabled('Config not loaded')
        return
    end

    local config = modules.config
    local changed = false
    local newVal

    ImGui.Text('Thresholds')
    ImGui.Separator()

    -- Emergency HP %
    newVal, changed = ImGui.SliderInt('Emergency HP %', config.emergencyPct, 10, 50)
    if changed then
        config.emergencyPct = newVal
    end
    ImGui.SameLine()
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Below this HP% triggers emergency healing')
    end

    -- Group Heal Min Count
    newVal, changed = ImGui.SliderInt('Group Heal Min Count', config.groupHealMinCount, 2, 5)
    if changed then
        config.groupHealMinCount = newVal
    end
    ImGui.SameLine()
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Minimum injured players to trigger group heal')
    end

    -- Group Heal Min Deficit (convert to k for display)
    local deficitK = math.floor(config.groupHealMinDeficit / 1000)
    newVal, changed = ImGui.SliderInt('Group Heal Min Deficit (k)', deficitK, 5, 50)
    if changed then
        config.groupHealMinDeficit = newVal * 1000
    end
    ImGui.SameLine()
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Minimum deficit per person for group heal consideration')
    end

    -- Squishy Max HP (convert to k for display)
    local squishyK = math.floor(config.squishyMaxHP / 1000)
    newVal, changed = ImGui.SliderInt('Squishy Max HP (k)', squishyK, 30, 150)
    if changed then
        config.squishyMaxHP = newVal * 1000
    end
    ImGui.SameLine()
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Players with max HP below this are considered squishy')
    end

    ImGui.Spacing()
    ImGui.Text('Heal Selection')
    ImGui.Separator()

    -- Squishy Coverage %
    newVal, changed = ImGui.SliderInt('Squishy Coverage %', config.squishyCoveragePct, 50, 100)
    if changed then
        config.squishyCoveragePct = newVal
    end
    ImGui.SameLine()
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Minimum deficit coverage for squishy targets')
    end

    -- Overheal Tolerance %
    newVal, changed = ImGui.SliderInt('Overheal Tolerance %', config.overhealTolerancePct, 0, 50)
    if changed then
        config.overhealTolerancePct = newVal
    end
    ImGui.SameLine()
    ImGui.TextDisabled('(?)')
    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Acceptable overheal percentage when choosing heals')
    end

    ImGui.Spacing()
    ImGui.Text('Spell Configuration')
    ImGui.Separator()

    -- Show spells in each category
    for category, spells in pairs(config.spells) do
        if ImGui.TreeNode(category:upper()) then
            -- List current spells with remove buttons
            for i, spell in ipairs(spells) do
                ImGui.Text(string.format('%d. %s', i, spell))
                ImGui.SameLine()
                if ImGui.SmallButton('Remove##' .. category .. i) then
                    table.remove(config.spells[category], i)
                end
            end

            -- Add from memorized spell gems
            ImGui.Text('Add from memorized spells:')
            for gem = 1, 13 do
                local spellName = mq.TLO.Me.Gem(gem).Name()
                if spellName and spellName ~= '' then
                    if ImGui.SmallButton(spellName .. '##add' .. category) then
                        -- Check if spell already exists before adding
                        local exists = false
                        for _, s in ipairs(config.spells[category]) do
                            if s == spellName then
                                exists = true
                                break
                            end
                        end
                        if not exists then
                            table.insert(config.spells[category], spellName)
                        end
                    end
                end
            end

            ImGui.TreePop()
        end
    end

    ImGui.Spacing()
    ImGui.Separator()

    -- Save Config button
    if ImGui.Button('Save Config') then
        local charName = mq.TLO.Me.Name() or 'Unknown'
        config.Save(charName)
        print('[DeficitHealer] Config saved!')
    end
    ImGui.SameLine()
    ImGui.TextDisabled('Saves to character-specific config file')
end

function UI.DrawCompact()
    -- Minimal view with just learning indicator and priority targets
    local isLearning = modules.healTracker and modules.healTracker.IsLearning()
    if isLearning then
        ImGui.TextColored(1.0, 0.9, 0.1, 1.0, 'LEARNING')
    else
        ImGui.TextColored(0.1, 0.9, 0.1, 1.0, 'ACTIVE')
    end

    ImGui.SameLine()

    -- Last action (compact)
    local lastAction = modules.healselector and modules.healselector.GetLastAction()
    if lastAction then
        -- Handle both string (legacy) and table formats
        if type(lastAction) == 'string' then
            ImGui.TextDisabled(string.format('| %s', lastAction))
        else
            ImGui.TextDisabled(string.format('| %s', lastAction.spell or ''))
        end
    end

    -- Priority targets only
    local priorityTargets = modules.targetMonitor and modules.targetMonitor.GetPriorityTargets() or {}
    for _, target in ipairs(priorityTargets) do
        local pctHP = target.pctHP or 100
        local r, g, b, a = getHPColor(pctHP)

        ImGui.Text(string.format('[%s] %s', target.role or '?', target.name or 'Unknown'))
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.PlotHistogram, r, g, b, a)
        ImGui.ProgressBar(pctHP / 100, 80, 12, string.format('%d%%', pctHP))
        ImGui.PopStyleColor()
    end

    if #priorityTargets == 0 then
        ImGui.TextDisabled('No priority targets')
    end
end

function UI.Draw()
    if not UI.open then
        return
    end

    -- Set window size constraints
    ImGui.SetNextWindowSize(400, 350, ImGuiCond.FirstUseEver)

    local open, show = ImGui.Begin('Deficit Healer', UI.open, ImGuiWindowFlags.None)
    UI.open = open

    if show then
        -- Compact/Expand toggle
        if UI.compact then
            if ImGui.Button('Expand') then
                UI.compact = false
            end
            ImGui.SameLine()
            UI.DrawCompact()
        else
            if ImGui.Button('Compact') then
                UI.compact = true
            end
            ImGui.Separator()

            -- Tab bar with all tabs
            if ImGui.BeginTabBar('DeficitHealerTabs') then
                if ImGui.BeginTabItem('Status') then
                    UI.currentTab = 'status'
                    UI.DrawStatusTab()
                    ImGui.EndTabItem()
                end

                if ImGui.BeginTabItem('Heal Data') then
                    UI.currentTab = 'healdata'
                    UI.DrawHealDataTab()
                    ImGui.EndTabItem()
                end

                if ImGui.BeginTabItem('Analytics') then
                    UI.currentTab = 'analytics'
                    UI.DrawAnalyticsTab()
                    ImGui.EndTabItem()
                end

                if ImGui.BeginTabItem('Config') then
                    UI.currentTab = 'config'
                    UI.DrawConfigTab()
                    ImGui.EndTabItem()
                end

                ImGui.EndTabBar()
            end
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
