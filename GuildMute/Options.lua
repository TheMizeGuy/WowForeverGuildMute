-- WoW Forever Guild Mute: the settings page (Esc > Options > AddOns > Guild Mute, or /gmute).
--
-- The Settings window gives an addon page about 665 x 600 pixels (Blizzard_SettingsPanel.xml:
-- a 920 x 724 panel minus the 199-pixel category list and margins). The page scrolls, so a long
-- channel list never runs off the bottom. Its controls are made the first time it is opened, so
-- a page nobody opens costs nothing.

local _, ns = ...
local Match, Store = ns.Match, ns.Store
local settings = ns.settings

local ROW = 24
local COLUMN = 300
local CONTENT_WIDTH = 610
local CHANNEL_COLUMNS = 4

local panel = CreateFrame("Frame")
panel:Hide()

local refreshers = {}
local built = false

local function Build()
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", -28, 4)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(CONTENT_WIDTH, 600)
    scroll:SetScrollChild(content)

    -- apply runs after the setting changes; by default the full settings change (filters, removal
    -- pass, save).
    local function Checkbox(label, x, y, getChecked, setChecked, apply)
        local check = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        check:SetSize(24, 24)
        check:SetPoint("TOPLEFT", x, y)
        check.Text:SetFontObject("GameFontHighlight")
        check.Text:SetText(label)
        check:SetScript("OnClick", function(self)
            setChecked(self:GetChecked() and true or false)
            if apply then
                apply()
            else
                ns.SettingsChanged(true)
            end
        end)
        refreshers[#refreshers + 1] = function()
            check:SetChecked(getChecked())
        end
        return check
    end

    local function Label(text, font, x, y, anchor)
        local label = content:CreateFontString(nil, "ARTWORK", font)
        if anchor then
            label:SetPoint("TOPLEFT", anchor, "TOPLEFT", x, y)
        else
            label:SetPoint("TOPLEFT", x, y)
        end
        label:SetJustifyH("LEFT")
        label:SetWidth(CONTENT_WIDTH - x)
        label:SetText(text)
        return label
    end

    Label("Guild Mute", "GameFontNormalLarge", 16, -12)
    Label("Hides chat from players whose guild name contains any of these words, in any letter case.",
        "GameFontHighlightSmall", 16, -36)

    local y = -58
    Checkbox("Hide chat from matching guilds", 12, y, function()
        return settings.enabled
    end, function(on)
        settings.enabled = on
    end)

    y = y - 30
    Label("Guild words or phrases, separated by commas (press Enter to apply):", "GameFontNormal", 16, y)
    local phraseBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    phraseBox:SetPoint("TOPLEFT", 22, y - 18)
    phraseBox:SetSize(CONTENT_WIDTH - 40, 24)
    phraseBox:SetAutoFocus(false)

    local function CommitPhrases()
        local text = phraseBox:GetText()
        if text ~= settings.phrases then
            settings.phrases = text
            ns.SettingsChanged(true)
        end
    end
    phraseBox:SetScript("OnEnterPressed", function(self)
        CommitPhrases()
        self:ClearFocus()
    end)
    phraseBox:SetScript("OnEditFocusLost", CommitPhrases)
    phraseBox:SetScript("OnEscapePressed", function(self)
        self:SetText(settings.phrases)
        self:ClearFocus()
    end)
    refreshers[#refreshers + 1] = function()
        if not phraseBox:HasFocus() then
            phraseBox:SetText(settings.phrases)
        end
    end

    y = y - 48
    Checkbox("Allow one typo in phrases of " .. Match.TYPO_MIN_LENGTH .. " or more letters (Olympus also matches Olypus)",
        12, y, function()
            return settings.typo
        end, function(on)
            settings.typo = on
        end)
    y = y - ROW
    Checkbox("Look up unknown senders with /who on your next key press or click", 12, y, function()
        return settings.lookup
    end, function(on)
        settings.lookup = on
    end)
    y = y - ROW
    Checkbox("Show the minimap button", 12, y, function()
        return settings.minimap
    end, function(on)
        settings.minimap = on
    end, function()
        ns.SaveSettings()
        ns.UpdateMinimapButton()
    end)

    y = y - 34
    Label("Hide their messages in:", "GameFontNormal", 16, y)
    y = y - 20
    local half = math.ceil(#ns.CATEGORIES / 2)
    for index, category in ipairs(ns.CATEGORIES) do
        local column = index > half and 1 or 0
        local row = column == 1 and (index - half - 1) or (index - 1)
        Checkbox(category.label, 12 + column * COLUMN, y - row * ROW, function()
            return not settings.shown[category.key]
        end, function(on)
            settings.shown[category.key] = (not on) or nil
        end)
    end
    y = y - half * ROW - 10

    Label("Channels you are in (unchecked channels keep showing them):", "GameFontNormal", 16, y)
    y = y - 20
    local channelTop = y
    local channelChecks = {}
    local noChannels = Label("You are not in any chat channel.", "GameFontDisable", 22, channelTop - 4)

    -- Everything below the channel list hangs from this marker, moved to fit the list's rows.
    local below = CreateFrame("Frame", nil, content)
    below:SetSize(1, 1)
    below:SetPoint("TOPLEFT", content, "TOPLEFT", 0, channelTop - ROW - 8)

    local testLabel = Label("Test a guild name:", "GameFontNormal", 16, -4, below)
    testLabel:SetWidth(130)
    local testBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    testBox:SetPoint("TOPLEFT", below, "TOPLEFT", 150, 0)
    testBox:SetSize(200, 24)
    testBox:SetAutoFocus(false)
    local testResult = Label("", "GameFontHighlight", 364, -4, below)

    local status = Label("", "GameFontHighlightSmall", 16, -34, below)
    local storage = Label("", "GameFontDisableSmall", 16, -66, below)

    -- One checkbox per joined channel, rebuilt whenever the page is shown.
    refreshers[#refreshers + 1] = function()
        local list = { GetChannelList() }
        local shown = 0
        for i = 1, #list, 3 do
            local name = list[i + 1]
            -- Community streams ("Community:<club>:<stream>") are covered by the Communities box.
            local key = type(name) == "string" and not name:find("^Community:") and Match.ChannelKey(name)
            if key then
                shown = shown + 1
                local check = channelChecks[shown]
                if not check then
                    check = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
                    check:SetSize(24, 24)
                    check.Text:SetFontObject("GameFontHighlight")
                    check:SetPoint("TOPLEFT", 12 + ((shown - 1) % CHANNEL_COLUMNS) * 150,
                        channelTop - math.floor((shown - 1) / CHANNEL_COLUMNS) * ROW)
                    check:SetScript("OnClick", function(self)
                        settings.shownChannels[self.channelKey] = (not self:GetChecked()) or nil
                        ns.SettingsChanged(true)
                    end)
                    channelChecks[shown] = check
                end
                check.channelKey = key
                check.Text:SetText(name)
                check:SetChecked(not settings.shownChannels[key])
                check:Show()
            end
        end
        for i = shown + 1, #channelChecks do
            channelChecks[i]:Hide()
        end
        noChannels:SetShown(shown == 0)
        local rows = math.max(1, math.ceil(shown / CHANNEL_COLUMNS))
        local top = channelTop - rows * ROW - 8
        below:ClearAllPoints()
        below:SetPoint("TOPLEFT", content, "TOPLEFT", 0, top)
        content:SetHeight(110 - top)
    end

    local function UpdateTest()
        local text = testBox:GetText()
        if text == "" then
            testResult:SetText("")
            return
        end
        local phrase, typo = Match.FindPhrase(text, ns.Phrases(), settings.typo)
        if phrase then
            testResult:SetText("|cffff6060hidden|r (matches \"" .. phrase .. "\"" .. (typo and ", one typo" or "") .. ")")
        else
            testResult:SetText("|cff60ff60shown|r")
        end
    end
    testBox:SetScript("OnTextChanged", UpdateTest)
    testBox:SetScript("OnEnterPressed", testBox.ClearFocus)
    testBox:SetScript("OnEscapePressed", testBox.ClearFocus)
    refreshers[#refreshers + 1] = UpdateTest

    refreshers[#refreshers + 1] = function()
        local known, matching = ns.KnownCounts()
        status:SetText(("Hidden %d lines this session. Guilds known for %d players, %d of them in a matching guild. %d /who lookups sent.")
            :format(ns.stats.hidden, known, matching, ns.stats.lookups))
        if Store.HasMacro() then
            storage:SetText("Settings are kept in the \"" .. Store.MACRO_NAME .. "\" macro (General tab), because this WoW Forever"
                .. " build does not load saved settings. You can edit its # lines by hand too.")
        else
            storage:SetText("Using the default settings. A change here is kept in a macro named \"" .. Store.MACRO_NAME
                .. "\", because this WoW Forever build does not load saved settings.")
        end
    end

    local forget = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    forget:SetSize(170, 22)
    forget:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -12)
    forget:SetText("Forget learned guilds")
    forget:SetScript("OnClick", function()
        ns.ForgetGuilds()
        ns.RefreshOptions()
    end)
end

local function RefreshAll()
    for _, refresh in ipairs(refreshers) do
        refresh()
    end
end

function ns.RefreshOptions()
    if built and panel:IsVisible() then
        RefreshAll()
    end
end

panel:SetScript("OnShow", function()
    if not built then
        built = true
        Build()
    end
    RefreshAll()
end)

-- Settings panel callbacks for canvas pages. OnDefault runs for this page's Defaults button and
-- for "All Settings"; it restores the defaults and deletes the settings macro. There is no
-- OnRefresh: showing the page already refreshes it, and the Settings window calls both.
function panel.OnDefault()
    for key, value in pairs(Store.Defaults()) do
        settings[key] = value
    end
    ns.SettingsChanged(true)
end
function panel.OnCommit() end

local category
if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, "Guild Mute")
    Settings.RegisterAddOnCategory(category)
end

function ns.OpenOptions()
    if not category or InCombatLockdown() then
        SlashCmdList.GUILDMUTE("status")
        return
    end
    Settings.OpenToCategory(category:GetID())
end
