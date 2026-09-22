-- A small fake of the WoW client API, enough to load the addon under LuaJIT and drive it with
-- chat events, unit sightings, /who replies, key presses, combat and macros.
-- Usage: local wow = dofile("tests/wow.lua"); local ns = wow.Load()

local wow = {}

local ADDON_DIR = (os.getenv("ADDON_DIR") or "GuildMute") .. "/"

-- enUS global strings the addon reads (Blizzard's GlobalStrings.lua is not in the UI source).
local STRINGS = {
    WHO_LIST_FORMAT = "|Hplayer:%s|h[%s]|h: Level %d %s %s - %s",
    WHO_LIST_GUILD_FORMAT = "|Hplayer:%s|h[%s]|h: Level %d %s %s <%s> - %s",
    WHO_NUM_RESULTS = "%d |4player:players; total",
    WHO_TAG_EXACT = "x-",
    UNKNOWNOBJECT = "Unknown",
    BNET_CLIENT_WOW = "WoW",
    WOW_PROJECT_ID = 1,
}

-- A value the fake canaccessvalue refuses, standing in for a 12.x secret value.
wow.SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })

-- A table canaccessvalue allows but canaccesstable refuses: indexing it raises an error.
local lockedTables = setmetatable({}, { __mode = "k" })
function wow.LockedTable()
    local proxy = setmetatable({}, { __index = function() error("attempt to index a secret table") end })
    lockedTables[proxy] = true
    return proxy
end

local function NoOp() end

-- Frames record scripts, events and keyboard state; any other method is a no-op.
local frameMethods = {}
frameMethods.__index = function(frame, key)
    local method = rawget(frameMethods, key)
    if method then
        return method
    end
    return NoOp
end
function frameMethods.SetScript(frame, name, fn)
    frame.scripts[name] = fn
    if name == "OnKeyDown" then
        wow.allKeyFrames[#wow.allKeyFrames + 1] = frame
    end
end
function frameMethods.GetScript(frame, name) return frame.scripts[name] end
function frameMethods.RegisterEvent(frame, event)
    if wow.unknownEvents[event] then
        error("unknown event " .. event)
    end
    if not next(frame.events) then
        wow.eventFrames[#wow.eventFrames + 1] = frame
    end
    frame.events[event] = true
end
function frameMethods.UnregisterEvent(frame, event) frame.events[event] = nil end
function frameMethods.IsEventRegistered(frame, event) return frame.events[event] == true end
function frameMethods.HookScript(frame, name, fn)
    local hooks = rawget(frame, "hooks") or {}
    frame.hooks = hooks
    hooks[name] = hooks[name] or {}
    table.insert(hooks[name], fn)
end
function frameMethods.SetHeight(frame, height) frame.height = height end
function frameMethods.EnableKeyboard(frame, on) frame.keyboard = on end
function frameMethods.SetPropagateKeyboardInput(frame, on)
    if wow.combat then
        error("SetPropagateKeyboardInput is protected in combat")
    end
    frame.propagate = on
end
function frameMethods.Show(frame) frame.shown = true; if frame.scripts.OnShow then frame.scripts.OnShow(frame) end end
function frameMethods.Hide(frame) frame.shown = false end
function frameMethods.SetShown(frame, on) frame.shown = on and true or false end
function frameMethods.IsShown(frame) return frame.shown end
function frameMethods.IsVisible(frame) return frame.shown end
function frameMethods.SetText(frame, text) frame.text = text end
function frameMethods.GetText(frame) return frame.text or "" end
function frameMethods.SetChecked(frame, on) frame.checked = on and true or false end
function frameMethods.GetChecked(frame) return frame.checked end
function frameMethods.HasFocus() return false end
function frameMethods.CreateFontString(frame) return wow.NewFrame() end
function frameMethods.CreateTexture(frame) return wow.NewFrame() end

function wow.NewFrame()
    local frame = setmetatable({ scripts = {}, events = {}, shown = true }, frameMethods)
    frame.Text = setmetatable({ scripts = {}, events = {}, shown = true }, frameMethods)
    return frame
end

-- Chat windows keep entries the way ScrollingMessageFrame does: message, r, g, b, extra data.
local function NewChatFrame(name)
    local frame = wow.NewFrame()
    frame.name = name
    frame.lines = {}
    function frame:AddMessage(message, r, g, b, ...)
        self.lines[#self.lines + 1] = { message = message, r = r, g = g, b = b, extra = { n = select("#", ...), ... } }
    end
    function frame:RemoveMessagesByPredicate(predicate)
        local kept = {}
        for _, line in ipairs(self.lines) do
            if not predicate(line.message, line.r, line.g, line.b, unpack(line.extra, 1, line.extra.n)) then
                kept[#kept + 1] = line
            end
        end
        self.lines = kept
    end
    function frame:TransformMessages(predicate, transform)
        for index, line in ipairs(self.lines) do
            if predicate(line.message, line.r, line.g, line.b, unpack(line.extra, 1, line.extra.n)) then
                local out = { transform(line.message, line.r, line.g, line.b, unpack(line.extra, 1, line.extra.n)) }
                self.lines[index] = { message = out[1], r = out[2], g = out[3], b = out[4],
                    extra = { n = #out - 4, select(5, unpack(out)) } }
            end
        end
    end
    return frame
end

function wow.Reset()
    wow.now = 1000
    wow.clock = 1700000000
    wow.combat = false
    wow.timers = {}
    wow.eventFrames = {}
    wow.unknownEvents = {}
    wow.filters = {}
    wow.printed = {}
    wow.whoQueries = {}
    wow.whoOrigins = {}
    wow.whoResults = {}
    wow.whoRefuses = false
    wow.units = {} -- [token] = { name =, realm =, guild =, guid =, player = true }
    wow.myGuild = nil
    wow.macros = {} -- General tab: { name =, icon =, body = }, macro indexes 1 to 120
    wow.charMacros = {} -- character tab, macro indexes 121 and up
    wow.shift = false
    wow.lockdown = false
    wow.macroWrites = 0
    wow.channels = { 1, "General", false, 2, "Trade", false }
    wow.bnet = {}
    wow.bubbles = {} -- { text =, forbidden = }; each becomes a fake bubble with a text frame
    wow.history = {} -- [chat history id] = chat type, for ChatHistory_GetChatType
    wow.allKeyFrames = {}
    wow.chat = { NewChatFrame("ChatFrame1"), NewChatFrame("ChatFrame2") }
    wow.whoToUi = false
    wow.clubs = {} -- [clubId] = { clubType = }
    wow.clubMessages = {} -- [messageId table] = message info

    local G = _G
    for _, name in ipairs(wow.namedFrames or {}) do
        G[name] = nil -- frames an earlier load created by name
    end
    wow.namedFrames = {}
    for key, value in pairs(STRINGS) do
        G[key] = value
    end
    G.CHAT_FRAMES = { "ChatFrame1", "ChatFrame2" }
    G.ChatFrame1, G.ChatFrame2 = wow.chat[1], wow.chat[2]
    G.GuildMuteDB = nil
    G.SlashCmdList = {}
    G.UIParent = wow.NewFrame()
    -- Forever: the Who list is the Group Finder's third tab; its Friends frame has no Who tab.
    G.FriendsFrame = wow.NewFrame()
    G.FriendsFrame.shown = false
    G.WhoFrame = nil
    G.LFGParentFrame = wow.NewFrame()
    G.LFGParentFrame.shown = false
    G.LFGWhoListFrame = wow.NewFrame()
    G.LFGWhoListFrame.shown = false
    G.LFGWhoListFrame:RegisterEvent("WHO_LIST_UPDATE") -- the Group Finder's Who list listens by default
    G.WorldFrame = wow.NewFrame()
    G.hooksecurefunc = function(target, name, hook)
        local original = target[name]
        target[name] = function(...)
            local results = { original(...) }
            hook(...)
            return unpack(results)
        end
    end
    -- The Communities window's chat, with Blizzard's AddMessage(clubId, streamId, message) shape.
    local communitiesChat = wow.NewFrame()
    communitiesChat.MessageFrame = NewChatFrame("CommunitiesMessageFrame")
    function communitiesChat:AddMessage(clubId, streamId, message)
        -- Blizzard's own code may read tables the addon cannot.
        if lockedTables[message] then
            message = {}
        end
        local author = type(message) == "table" and type(message.author) == "table" and not lockedTables[message.author]
            and message.author.name or "?"
        local content = type(message) == "table" and message.content or "?"
        self.MessageFrame:AddMessage("[" .. tostring(author) .. "]: " .. tostring(content), 1, 1, 1, clubId, streamId,
            type(message) == "table" and message.messageId or nil, 1)
    end
    G.CommunitiesFrame = wow.NewFrame()
    G.CommunitiesFrame.Chat = communitiesChat
    G.C_Club = {
        GetClubInfo = function(clubId) return wow.clubs[clubId] end,
        GetMessageInfo = function(_, _, messageId) return wow.clubMessages[messageId] end,
    }
    G.ChatTypeInfo = { ACHIEVEMENT = { id = 30 }, GUILD_ACHIEVEMENT = { id = 31 }, SAY = { id = 1 } }
    G.Enum = {
        GameRule = { IngameWhoListDisabled = 42 },
        SocialWhoOrigin = { Unknown = 0, Social = 1, Chat = 2, Item = 3 },
        ClubType = { BattleNet = 0, Character = 1, Guild = 2, Other = 3 },
    }
    G.C_ChatInfo = {
        InChatMessagingLockdown = function() return wow.lockdown end,
        IsChatLineCensored = function() return false end,
    }
    G.IsShiftKeyDown = function() return wow.shift end
    G.UnitGUID = function(unit)
        if unit == "player" then return "Player-1-ME" end
        local u = wow.units[unit]
        return u and u.guid
    end
    G.C_GameRules = { IsGameRuleActive = function() return false end }
    G.Constants = { MacroConsts = { MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 18 } }

    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[#parts + 1] = tostring((select(i, ...)))
        end
        wow.printed[#wow.printed + 1] = table.concat(parts, " ")
    end
    wow.frames = {}
    G.CreateFrame = function(_, name, _, template)
        local frame = wow.NewFrame()
        wow.frames[#wow.frames + 1] = frame
        if name then
            G[name] = frame
            wow.namedFrames[#wow.namedFrames + 1] = name
        end
        if template == "InsecureKeyboardInputPropagatorTemplate" then
            frame.propagate = true -- propagateKeyboardInput="true" in Blizzard's XML
        end
        return frame
    end
    G.GetTime = function() return wow.now end
    G.time = function() return wow.clock end
    G.InCombatLockdown = function() return wow.combat end
    G.canaccessvalue = function(...)
        for i = 1, select("#", ...) do
            if select(i, ...) == wow.SECRET then
                return false
            end
        end
        return true
    end
    G.canaccesstable = function(value)
        return value ~= wow.SECRET and not lockedTables[value]
    end
    G.C_Timer = {
        After = function(delay, fn)
            wow.timers[#wow.timers + 1] = { at = wow.now + delay, fn = fn }
        end,
    }
    G.GetNormalizedRealmName = function() return "Forever" end
    G.UnitExists = function(unit) return unit == "player" or wow.units[unit] ~= nil end
    G.UnitIsPlayer = function(unit)
        if unit == "player" then return true end
        local u = wow.units[unit]
        if not u then return false end
        if u.player == nil then return true end
        return u.player
    end
    G.UnitIsUnit = function(a, b) return a == b end
    G.UnitName = function(unit)
        if unit == "player" then return "Me", nil end
        local u = wow.units[unit]
        if u then return u.name, u.realm end
    end
    G.GetGuildInfo = function(unit)
        if unit == "player" then return wow.myGuild end
        local u = wow.units[unit]
        return u and u.guild
    end
    G.UnitTokenFromGUID = function(guid)
        for token, u in pairs(wow.units) do
            if u.guid == guid then return token end
        end
    end
    G.IsInRaid = function() return false end
    G.GetNumGroupMembers = function() return 0 end
    G.GetNumSubgroupMembers = function() return 0 end
    G.GetChannelList = function() return unpack(wow.channels) end
    G.ChatFrameUtil = {
        AddMessageEventFilter = function(event, fn)
            wow.filters[event] = wow.filters[event] or {}
            table.insert(wow.filters[event], fn)
        end,
        RemoveMessageEventFilter = function(event, fn)
            for index, filter in ipairs(wow.filters[event] or {}) do
                if filter == fn then
                    table.remove(wow.filters[event], index)
                    break
                end
            end
        end,
    }
    -- The minimap, the cursor, menus and tooltips for the minimap button.
    G.Minimap = wow.NewFrame()
    function G.Minimap.GetWidth() return 140 end
    function G.Minimap.GetCenter() return 1000, 600 end
    function G.Minimap.GetEffectiveScale() return 1 end
    wow.cursor = { 1000, 700 }
    G.GetCursorPosition = function() return wow.cursor[1], wow.cursor[2] end
    G.MenuUtil = {
        CreateContextMenu = function(owner, generator)
            local menu = { items = {} }
            local root = {}
            function root:CreateTitle(text) table.insert(menu.items, { kind = "title", text = text }) end
            function root:CreateCheckbox(text, isSelected, setSelected)
                table.insert(menu.items, { kind = "checkbox", text = text, isSelected = isSelected, setSelected = setSelected })
            end
            function root:CreateButton(text, onClick) table.insert(menu.items, { kind = "button", text = text, onClick = onClick }) end
            generator(owner, root)
            wow.menu = menu
            return menu
        end,
    }
    G.GameTooltip = wow.NewFrame()
    G.GameTooltip_Hide = NoOp
    G.UpdateAddOnMemoryUsage = NoOp
    G.GetAddOnMemoryUsage = function() return 123.4 end
    G.C_FriendList = {
        SendWho = function(query, origin)
            wow.whoQueries[#wow.whoQueries + 1] = query
            wow.whoOrigins[#wow.whoOrigins + 1] = origin
            if wow.whoRefuses then
                wow.Fire("ADDON_ACTION_BLOCKED", "GuildMute", "C_FriendList.SendWho()")
            end
        end,
        GetNumWhoResults = function() return #wow.whoResults, #wow.whoResults end,
        SetWhoToUi = function(on) wow.whoToUi = on end,
        GetWhoInfo = function(i) return wow.whoResults[i] end,
    }
    G.HideUIPanel = function(frame) frame.shown = false end
    G.C_BattleNet = { GetAccountInfoByID = function(id) return wow.bnet[id] end }
    G.ChatHistory_GetChatType = function(id)
        local entry = wow.history[id]
        if type(entry) == "table" then
            return unpack(entry) -- chat type, chat target, sender GUID
        end
        return entry
    end
    G.GetChannelName = function(index)
        for i = 1, #wow.channels, 3 do
            if wow.channels[i] == index then return index, wow.channels[i + 1] end
        end
        return 0
    end
    G.C_ChatBubbles = {
        GetAllChatBubbles = function(includeForbidden)
            local list = {}
            for _, bubble in ipairs(wow.bubbles) do
                if includeForbidden or not bubble.forbidden then
                    bubble.frame = bubble.frame or wow.NewFrame()
                    if rawget(bubble.frame, "alpha") == nil then
                        bubble.frame.alpha = 1
                    end
                    bubble.frame.SetAlpha = function(self, a) self.alpha = a end
                    bubble.frame.String = { GetText = function() return bubble.text end }
                    list[#list + 1] = { GetChildren = function() return bubble.frame end }
                end
            end
            return list
        end,
    }

    -- Macro indexes follow the client: General tab 1 to 120, character tab from 121.
    local function Slot(index)
        if index > 120 then
            return wow.charMacros, index - 120
        end
        return wow.macros, index
    end
    G.GetNumMacros = function() return #wow.macros, #wow.charMacros end
    G.GetMacroIndexByName = function(name)
        for index, macro in ipairs(wow.macros) do
            if macro.name == name then return index end
        end
        for index, macro in ipairs(wow.charMacros) do
            if macro.name == name then return 120 + index end
        end
        return 0
    end
    G.GetMacroInfo = function(index)
        local list, i = Slot(index)
        local macro = list[i]
        if macro then return macro.name, macro.icon, macro.body end
    end
    local function Protected(name)
        if wow.combat then
            error(name .. " is protected in combat")
        end
        wow.macroWrites = wow.macroWrites + 1
    end
    G.CreateMacro = function(name, icon, body, perCharacter)
        Protected("CreateMacro")
        local list = perCharacter and wow.charMacros or wow.macros
        list[#list + 1] = { name = name, icon = icon, body = body or "" }
        return perCharacter and (120 + #list) or #list
    end
    G.EditMacro = function(index, name, icon, body)
        Protected("EditMacro")
        local list, i = Slot(index)
        local macro = list[i]
        macro.name = name or macro.name
        macro.icon = icon or macro.icon
        macro.body = body or macro.body
        return index
    end
    G.DeleteMacro = function(index)
        Protected("DeleteMacro")
        local list, i = Slot(index)
        table.remove(list, i)
    end
    G.Settings = {
        RegisterCanvasLayoutCategory = function(frame, name)
            wow.optionsPanel = frame
            return { GetID = function() return 77 end, name = name }
        end,
        RegisterAddOnCategory = NoOp,
        OpenToCategory = function(id) wow.openedCategory = id end,
    }
end

-- Loads the addon's files in TOC order with a fresh namespace, then logs in.
function wow.Load(options)
    options = options or {}
    wow.Reset()
    if options.setup then
        options.setup()
    end
    local ns = {}
    wow.ns = ns
    local toc = assert(io.open(ADDON_DIR .. "GuildMute.toc")):read("*a")
    for file in toc:gmatch("\n([%w_]+%.lua)") do
        assert(loadfile(ADDON_DIR .. file))("GuildMute", ns)
    end
    wow.Fire("ADDON_LOADED", "GuildMute")
    if options.login ~= false then
        wow.Fire("PLAYER_LOGIN")
    end
    return ns
end

function wow.Fire(event, ...)
    for _, frame in ipairs(wow.eventFrames) do
        if frame.events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event, ...)
        end
    end
end

-- Runs timers that are due, including ones they schedule.
function wow.Advance(seconds)
    wow.now = wow.now + (seconds or 0)
    local ran = true
    while ran do
        ran = false
        for index, timer in ipairs(wow.timers) do
            if timer.at <= wow.now then
                table.remove(wow.timers, index)
                timer.fn()
                ran = true
                break
            end
        end
    end
end

local nextLine = 1

-- Delivers a chat event the way ChatFrameMixin:MessageEventHandler does: filters first (once per
-- window; a filter may rewrite the arguments), then AddMessage of the formatted text with the
-- event, the original arguments and the formatter as extra data.
-- args: text, author, guid, channel (base name, CHAT_MSG_CHANNEL only), bnSenderID.
function wow.Chat(event, args)
    nextLine = nextLine + 1
    local a = {}
    a[1] = args.text or "hello"
    a[2] = args.author or ""
    a[3] = ""
    a[4] = args.channel and ("2. " .. args.channel) or ""
    a[5] = ""
    a[6] = ""
    a[7] = args.channel and 2 or 0
    a[8] = args.channel and 2 or 0
    a[9] = args.channel or ""
    a[10] = 0
    a[11] = args.lineID or nextLine
    a[12] = args.guid or ""
    a[13] = args.bnSenderID or 0
    a[14] = false
    a.n = 14
    local shown = 0
    for _, frame in ipairs(wow.chat) do
        local discard = false
        local current = { unpack(a, 1, 14) }
        for _, filter in ipairs(wow.filters[event] or {}) do
            local results = { filter(frame, event, unpack(current, 1, 14)) }
            if results[1] then
                discard = true
                break
            end
            if results[2] then
                current = { select(2, unpack(results, 1, 15)) }
            end
        end
        if not discard then
            shown = shown + 1
            local author = current[2]
            local function MessageFormatter(msg)
                return "[" .. author .. "]: " .. msg
            end
            frame:AddMessage(MessageFormatter(current[1]), 1, 1, 1, 1, 1, 1, event, a, MessageFormatter)
        end
    end
    return shown > 0
end

-- Delivers a system line through the CHAT_MSG_SYSTEM filters; returns true if it stays visible.
function wow.System(text)
    local shown = false
    for _, frame in ipairs(wow.chat) do
        local discard = false
        for _, filter in ipairs(wow.filters.CHAT_MSG_SYSTEM or {}) do
            if filter(frame, "CHAT_MSG_SYSTEM", text) then
                discard = true
            end
        end
        if not discard then
            shown = true
            frame:AddMessage(text, 1, 1, 0)
        end
    end
    return shown
end

function wow.WhoLine(name, guild, level)
    if guild then
        return string.format(STRINGS.WHO_LIST_GUILD_FORMAT, name, name, level or 20, "Human", "Warrior", guild, "Elwynn Forest")
    end
    return string.format(STRINGS.WHO_LIST_FORMAT, name, name, level or 20, "Human", "Warrior", "Elwynn Forest")
end

-- A click in the game world runs WorldFrame's OnMouseDown hooks.
function wow.WorldClick()
    for _, hook in ipairs((rawget(WorldFrame, "hooks") or {}).OnMouseDown or {}) do
        hook(WorldFrame, "LeftButton")
    end
end

-- A key press reaches keyboard-enabled frames that propagate input (as the addon's watcher does).
function wow.KeyPress(key)
    for _, frame in ipairs(wow.allKeyFrames) do
        if frame.shown and rawget(frame, "keyboard") and rawget(frame, "propagate") then
            frame.scripts.OnKeyDown(frame, key or "W")
        end
    end
end

-- Lines currently in the first chat window whose text contains needle.
function wow.CountLines(needle, frameIndex)
    local count = 0
    local frame = frameIndex == "Communities" and CommunitiesFrame.Chat.MessageFrame or wow.chat[frameIndex or 1]
    for _, line in ipairs(frame.lines) do
        if type(line.message) == "string" and line.message:find(needle, 1, true) then
            count = count + 1
        end
    end
    return count
end

-- Whether any frame the addon created shows this label (checkbox text, button text).
function wow.Labelled(text)
    for _, frame in ipairs(wow.frames) do
        if rawget(frame, "text") == text or rawget(frame.Text, "text") == text then
            return true
        end
    end
    return false
end

function wow.Printed(needle)
    for _, line in ipairs(wow.printed) do
        if line:find(needle, 1, true) then
            return true
        end
    end
    return false
end

return wow
