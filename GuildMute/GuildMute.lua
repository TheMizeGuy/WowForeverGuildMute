-- WoW Forever Guild Mute
-- Hides chat from players whose guild name contains a word or phrase ("Olympus" by default).
--
-- Chat events carry the sender's name and GUID but not their guild, and the client has no call
-- that returns another player's guild by name. The addon learns guilds from:
--   * units the client can see: target, mouseover, focus, nameplates, party and raid members;
--   * /who result lines, including the ones Blizzard prints when you shift-click a name;
--   * its own exact-name /who for a sender it cannot place yet. WoW only accepts /who during a
--     key press or mouse click (which is why shift-click works), so the query waits for the
--     next one, and its reply is kept out of chat.
-- Once a sender turns out to be in a matching guild, the lines they posted before that are
-- removed from every chat window, so an unknown whisperer's message disappears a moment after
-- the lookup answers.

local ADDON_NAME, ns = ...
local Match, Store = ns.Match, ns.Store

local ipairs, next, pairs, pcall, select, tonumber, type = ipairs, next, pairs, pcall, select, tonumber, type
local tinsert, tremove = table.insert, table.remove
local unpack = unpack or table.unpack

local CACHE_DAYS = 14 -- forget a player's guild after this long without seeing them
local KEY_CACHE_MAX = 4000 -- most cached name keys before the cache starts over
local UNRESOLVED_MAX = 1000 -- most senders tracked as shown while their guild was unknown
local BN_LINE_MAX = 500 -- most Battle.net whisper lines whose character is remembered
local TRIED_MAX = 1000 -- most players remembered as already looked up before that list starts over
local LOOKUP_INTERVAL = 5 -- seconds between the addon's own /who queries
local LOOKUP_INTERVAL_MAX = 30 -- the slowest pace after replies went missing
local LOOKUP_TIMEOUT = 10 -- seconds to wait for a /who reply
local LOOKUP_QUEUE_MAX = 30
local LATE_REPLY_WINDOW = 30 -- seconds a reply arriving after its query timed out is still hidden
local PREFIX = "|cff66ccff[Guild Mute]|r "

-- Chat types the addon hides, in settings order. All of them are hidden by default.
ns.CATEGORIES = {
    { key = "say", label = "Say", events = { "CHAT_MSG_SAY" } },
    { key = "yell", label = "Yell", events = { "CHAT_MSG_YELL" } },
    { key = "emote", label = "Emotes", events = { "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE" } },
    {
        key = "whisper",
        label = "Whispers and your replies",
        events = { "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_AFK", "CHAT_MSG_DND" },
    },
    { key = "bnet", label = "Battle.net whispers", events = { "CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM" } },
    { key = "party", label = "Party", events = { "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" } },
    {
        key = "raid",
        label = "Raid and raid warnings",
        events = { "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING" },
    },
    { key = "instance", label = "Instance and battleground", events = { "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER" } },
    { key = "guild", label = "Guild", events = { "CHAT_MSG_GUILD" } },
    { key = "officer", label = "Officer", events = { "CHAT_MSG_OFFICER" } },
    { key = "channel", label = "Channels (General, Trade, custom)", events = { "CHAT_MSG_CHANNEL" } },
    { key = "community", label = "Communities", events = { "CHAT_MSG_COMMUNITIES_CHANNEL" } },
    { key = "achievement", label = "Achievement announcements", events = { "CHAT_MSG_ACHIEVEMENT", "CHAT_MSG_GUILD_ACHIEVEMENT" } },
    { key = "voice", label = "Voice chat transcripts", events = { "CHAT_MSG_VOICE_TEXT" } },
}

local categoryOfEvent = {}
for _, category in ipairs(ns.CATEGORIES) do
    for _, event in ipairs(category.events) do
        categoryOfEvent[event] = category.key
    end
end

-- Everyone who can post these is in the player's own guild.
local OWN_GUILD_EVENTS = { CHAT_MSG_GUILD = true, CHAT_MSG_OFFICER = true, CHAT_MSG_GUILD_ACHIEVEMENT = true }
local BNET_EVENTS = { CHAT_MSG_BN_WHISPER = true, CHAT_MSG_BN_WHISPER_INFORM = true }

local settings = Store.Defaults()
ns.settings = settings
-- What the addon knows about players, kept compact because a busy city fills it quickly:
-- guilds[name key] = guild name ("" when /who found none; players of one guild share one string).
-- seenDay[name key] = the day a player loaded from an earlier session was last confirmed; players
-- confirmed this session have no entry until logout, when they are all stamped with today.
local guilds, seenDay = {}, {}
local knownCount = 0
local matchingCount -- how many known players match; nil until counted after a phrase change
local phrases = {} -- folded phrases from settings.phrases
local matchMemo = {} -- [guild name] = matching phrase or false
local homeRealm, myKey, myGUID
local stats = { hidden = 0, lookups = 0 }
ns.stats = stats
-- Hiding is on and there is something to hide. The addon does no work at all otherwise: no chat
-- filters, no unit events, no key watching.
local active = true

local function Print(message)
    print(PREFIX .. message)
end
ns.Print = Print

-- 12.x hands addons "secret" values in some unit and chat contexts; comparing one raises an
-- error, so anything read from a unit is checked before it is compared, even with nil.
local function Readable(value)
    return not canaccessvalue or canaccessvalue(value)
end

-- A table the addon may index: readable itself, and not one whose contents are secret (the same
-- test Blizzard's /dump uses).
local function ReadableTable(value)
    return Readable(value) and type(value) == "table" and (not canaccesstable or canaccesstable(value))
end

local function Today()
    return math.floor(time() / 86400)
end

-- Name keys, cached: the same few hundred authors and units come round all day.
local keyCache, keyCacheSize = {}, 0

local function KeyOf(name)
    if type(name) ~= "string" then
        return nil
    end
    local key = keyCache[name]
    if key ~= nil then
        return key or nil
    end
    if not homeRealm and GetNormalizedRealmName then
        homeRealm = GetNormalizedRealmName()
    end
    key = Match.NameKey(name, homeRealm)
    if key == nil and not homeRealm then
        return nil -- the realm is not known yet; do not remember the failure
    end
    if keyCacheSize >= KEY_CACHE_MAX then
        keyCache, keyCacheSize = {}, 0
    end
    keyCache[name] = key or false
    keyCacheSize = keyCacheSize + 1
    return key
end
ns.KeyOf = KeyOf

-- The player's own lines are never hidden. The GUID check covers the moment after login when
-- the realm name (part of the name key) may not be known yet.
local function IsMe(key, guid)
    myKey = myKey or KeyOf(UnitName("player"))
    myGUID = myGUID or UnitGUID("player")
    return (key ~= nil and key == myKey) or (type(guid) == "string" and guid ~= "" and guid == myGUID)
end

-- Matching ------------------------------------------------------------------------------------

local function CompilePhrases()
    phrases = Match.ParsePhrases(settings.phrases)
    matchMemo = {}
    matchingCount = nil
end

-- The phrase a guild name matches, or nil.
function ns.GuildMatches(guild)
    if type(guild) ~= "string" or guild == "" then
        return nil
    end
    local memo = matchMemo[guild]
    if memo == nil then
        memo = Match.FindPhrase(guild, phrases, settings.typo) or false
        matchMemo[guild] = memo
    end
    return memo or nil
end

function ns.Phrases()
    return phrases
end

-- Removing lines that are already on screen -----------------------------------------------------

-- Defined further down: the purge replays each stored line through Evaluate, and a Battle.net
-- line's sender is the friend's current character (BNetCharacter).
local Evaluate, BNetCharacter

-- Senders whose lines were shown while their guild was unknown. Learning that one of them is in a
-- matching guild removes their lines; learning a guild for anyone else needs no pass at all.
-- Chat windows keep a few hundred lines, so every full pass rebuilds the set from the lines still
-- on screen, which also clears an overflow.
local unresolved, unresolvedCount, unresolvedOverflow = {}, 0, false
-- [lineID] = the character a Battle.net whisper came from, noted while its guild was unknown, so
-- the line is still found if the friend switches characters first. Every full pass rebuilds it
-- from the lines still on screen; past BN_LINE_MAX it starts over (a line then falls back to the
-- friend's current character).
local bnLineKeys, bnLineCount = {}, 0
local bnLinesAfterPass -- the table a full pass rebuilds, swapped in when the pass ends

local function NoteBNetLine(lineID, key)
    if bnLinesAfterPass then
        bnLinesAfterPass[lineID] = key
        return
    end
    if bnLineKeys[lineID] then
        return -- the same line, met in another chat window
    end
    if bnLineCount >= BN_LINE_MAX then
        bnLineKeys, bnLineCount = {}, 0
    end
    bnLineKeys[lineID] = key
    bnLineCount = bnLineCount + 1
end

local function NoteUnresolved(key)
    if unresolved[key] then
        return
    end
    if unresolvedCount >= UNRESOLVED_MAX then
        unresolvedOverflow = true -- lost track; the next removal pass looks at every line
        return
    end
    unresolved[key] = true
    unresolvedCount = unresolvedCount + 1
end

-- The event behind a line stored without one: achievement lines carry only their chat type's
-- id, and lines copied into a newly opened whisper window keep only their chat history id,
-- which ChatHistory_GetChatType turns back into the chat type ("WHISPER", "CHANNEL5").
-- Returns the event and, for channels, the channel's name.
local function StoredLineEvent(chatTypeID, typeID)
    local info = ChatTypeInfo
    if info and chatTypeID ~= nil then
        if info.ACHIEVEMENT and chatTypeID == info.ACHIEVEMENT.id then
            return "CHAT_MSG_ACHIEVEMENT"
        elseif info.GUILD_ACHIEVEMENT and chatTypeID == info.GUILD_ACHIEVEMENT.id then
            return "CHAT_MSG_GUILD_ACHIEVEMENT"
        end
    end
    if type(typeID) ~= "number" or not ChatHistory_GetChatType then
        return nil
    end
    local chatType = ChatHistory_GetChatType(typeID)
    if type(chatType) ~= "string" then
        return nil
    end
    local channelIndex = tonumber(chatType:match("^CHANNEL(%d+)$"))
    if channelIndex then
        return "CHAT_MSG_CHANNEL", GetChannelName and select(2, GetChannelName(channelIndex))
    end
    local event = "CHAT_MSG_" .. chatType
    if categoryOfEvent[event] then
        return event
    end
end

-- The purge in progress: nil for every line, or the set of sender keys to look at.
local purgeOnly

-- Chat lines carry their original event and arguments (Blizzard keeps them so a censored line
-- can be re-formatted), which is what lets the purge judge a line after the fact.
local function IsHiddenLine(text, _, _, _, chatTypeID, _, typeID, event, eventArgs)
    if event == nil then
        if not (Readable(text) and Readable(chatTypeID) and Readable(typeID)) or type(text) ~= "string" then
            return false
        end
        local name = text:match("|Hplayer:([^:|]+)")
        if not name or (purgeOnly and not purgeOnly[KeyOf(name)]) then
            return false
        end
        local storedEvent, channelName = StoredLineEvent(chatTypeID, typeID)
        if storedEvent == nil then
            return false
        end
        local hide, unknownKey = Evaluate(storedEvent, not purgeOnly, nil, name, nil, nil, nil, nil, nil, nil, channelName)
        if not hide and unknownKey and not purgeOnly then
            NoteUnresolved(unknownKey) -- a full pass: still on screen, guild still unknown
        end
        return hide
    end
    if type(event) ~= "string" or type(eventArgs) ~= "table" or not categoryOfEvent[event] then
        return false
    end
    if purgeOnly then
        -- Only the named senders: a cheap look at the sender before anything else. A Battle.net
        -- line names the friend's account, so its sender is their current character.
        local key
        if event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_BN_WHISPER_INFORM" then
            -- The character the friend was on when the line was shown, if it was noted then.
            local lineID, id = eventArgs[11], eventArgs[13]
            key = Readable(lineID) and bnLineKeys[lineID] or (Readable(id) and BNetCharacter(id))
        else
            local author = eventArgs[2]
            key = Readable(author) and KeyOf(author)
        end
        if not key or not purgeOnly[key] then
            return false
        end
    end
    local count = eventArgs.n or #eventArgs
    if canaccessvalue and not canaccessvalue(unpack(eventArgs, 1, count)) then
        return false
    end
    local hide, unknownKey = Evaluate(event, not purgeOnly, unpack(eventArgs, 1, count))
    if not hide and unknownKey and not purgeOnly then
        NoteUnresolved(unknownKey) -- a full pass: still on screen, guild still unknown
        local lineID = eventArgs[11]
        if BNET_EVENTS[event] and lineID and lineID ~= 0 then
            NoteBNetLine(lineID, unknownKey)
        end
    end
    return hide
end

local purgeKeys, purgeAll, purgeScheduled = {}, false, false
local WaitForMacros, HookCommunities, UpdateKeyWatch -- defined with the events below

local function PurgeNow()
    local keys, all = purgeKeys, purgeAll
    purgeKeys, purgeAll, purgeScheduled = {}, false, false
    if not active then
        return
    end
    purgeOnly = not all and keys or nil
    -- A full pass rebuilds both from the lines still on screen; the old Battle.net notes are read
    -- until it ends.
    bnLinesAfterPass = all and {} or nil
    if all then
        unresolved, unresolvedCount, unresolvedOverflow = {}, 0, false
    end
    for _, frameName in ipairs(CHAT_FRAMES or {}) do
        local frame = _G[frameName]
        if frame and frame.RemoveMessagesByPredicate then
            frame:RemoveMessagesByPredicate(IsHiddenLine)
        end
    end
    if bnLinesAfterPass then
        local count = 0
        for _ in pairs(bnLinesAfterPass) do
            count = count + 1
        end
        bnLineKeys, bnLineCount, bnLinesAfterPass = bnLinesAfterPass, count, nil
    end
    if ns.PurgeCommunities then
        ns.PurgeCommunities(purgeOnly)
    end
    purgeOnly = nil
end
ns.PurgeNow = function()
    purgeAll = true
    PurgeNow()
end

-- Removes, on the next frame, the lines of the sender with this key, or of everyone (nil) after a
-- settings change. Several guilds learned in one frame share one pass.
local function SchedulePurge(key)
    if key == nil then
        purgeAll = true
    else
        purgeKeys[key] = true
    end
    if not purgeScheduled then
        purgeScheduled = true
        C_Timer.After(0, PurgeNow)
    end
end

-- Guild knowledge -------------------------------------------------------------------------------

local function Remember(key, guild)
    if not key or type(guild) ~= "string" then
        return
    end
    local previous = guilds[key]
    if previous == guild then
        seenDay[key] = nil -- confirmed again this session
        return
    end
    if previous == nil then
        knownCount = knownCount + 1
    end
    guilds[key], seenDay[key] = guild, nil
    local shown = unresolved[key]
    if shown then
        unresolved[key] = nil
        unresolvedCount = unresolvedCount - 1
    end
    if ns.GuildMatches(guild) then
        if unresolvedOverflow then
            SchedulePurge(nil) -- lost track of who was shown; a full pass also rebuilds the list
        elseif shown or (previous ~= nil and not ns.GuildMatches(previous)) then
            SchedulePurge(key) -- their lines on screen, or a player who has just joined
        end
    end
    if matchingCount then
        local nowMatches, matchedBefore = ns.GuildMatches(guild) ~= nil, ns.GuildMatches(previous) ~= nil
        if nowMatches ~= matchedBefore then
            matchingCount = matchingCount + (nowMatches and 1 or -1)
        end
    end
end
ns.Remember = Remember

function ns.GuildOfKey(key)
    return key and guilds[key]
end

-- Records a visible player's guild. A nil guild from a unit usually just means the client has
-- not received it yet, so only PLAYER_GUILD_UPDATE (authoritative) records "no guild". The cheap
-- checks come first: most units in a busy place are creatures or players with no guild data.
local function ObserveUnit(unit, authoritative)
    if not active or not unit then
        return
    end
    local isPlayer = UnitIsPlayer(unit)
    if not Readable(isPlayer) or not isPlayer then
        return
    end
    local guild = GetGuildInfo(unit)
    if not Readable(guild) or ((guild == nil or guild == "") and not authoritative) then
        return
    end
    local isMe = UnitIsUnit(unit, "player")
    if not Readable(isMe) or isMe then
        return
    end
    local name, realm = UnitName(unit)
    if not Readable(name) or not Readable(realm) or not name or name == "" or name == UNKNOWNOBJECT then
        return
    end
    -- Most units are seen once, so their key skips the cache that serves repeat chat authors.
    if not homeRealm and GetNormalizedRealmName then
        homeRealm = GetNormalizedRealmName()
    end
    local key = Match.NameKey((realm and realm ~= "") and (name .. "-" .. realm) or name, homeRealm)
    Remember(key, guild or "")
end
ns.ObserveUnit = ObserveUnit

local function ObserveGroup()
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            ObserveUnit("raid" .. i, false)
        end
    else
        for i = 1, GetNumSubgroupMembers() do
            ObserveUnit("party" .. i, false)
        end
    end
end

-- The cache first; a live unit for the sender (party, target, nameplate) when it has nothing.
local function GuildOf(key, guid)
    local guild = guilds[key]
    if guild == nil and UnitTokenFromGUID and type(guid) == "string" and guid ~= "" then
        local unit = UnitTokenFromGUID(guid)
        if Readable(unit) and unit then
            ObserveUnit(unit, false)
            guild = guilds[key]
        end
    end
    return guild
end

-- A Battle.net friend's current Forever character, if they are on one.
BNetCharacter = function(bnSenderID)
    if type(bnSenderID) ~= "number" or bnSenderID == 0 or not (C_BattleNet and C_BattleNet.GetAccountInfoByID) then
        return nil
    end
    local info = C_BattleNet.GetAccountInfoByID(bnSenderID)
    local game = info and info.gameAccountInfo
    if not game or game.clientProgram ~= (BNET_CLIENT_WOW or "WoW") or type(game.characterName) ~= "string" then
        return nil
    end
    if WOW_PROJECT_ID and game.wowProjectID and game.wowProjectID ~= WOW_PROJECT_ID then
        return nil
    end
    local name = game.characterName
    if type(game.realmName) == "string" and game.realmName ~= "" then
        name = name .. "-" .. game.realmName
    end
    return KeyOf(name), game.playerGuid
end

-- Loads the saved knowledge (SavedVariables, once Blizzard fixes loading them), dropping entries
-- older than CACHE_DAYS and converting the first release's { guild, time } entries.
local function LoadGuilds(savedGuilds, savedDays)
    local cutoff = Today() - CACHE_DAYS
    guilds, seenDay, knownCount = {}, {}, 0
    for key, value in pairs(savedGuilds) do
        local guild, day = value, savedDays[key]
        if type(value) == "table" then
            guild, day = value[1], type(value[2]) == "number" and math.floor(value[2] / 86400) or nil
        end
        if type(key) == "string" and type(guild) == "string" and type(day) == "number" and day >= cutoff then
            guilds[key], seenDay[key] = guild, day
            knownCount = knownCount + 1
        end
    end
    return guilds, seenDay
end

-- Lookups -----------------------------------------------------------------------------------------

local lookup = {
    queue = {}, -- { name = sender as written, key = name key, urgent = whisper }, whispers first
    queued = {}, -- [key] = true while in the queue
    tried = {}, -- [key] = true once looked up; starts over past TRIED_MAX
    triedCount = 0,
    recent = {}, -- [key] = GetTime() until which a late reply to an earlier query is still hidden
    lastSent = -LOOKUP_INTERVAL_MAX,
    interval = LOOKUP_INTERVAL, -- doubles after a lost reply: the server drops /who sent too fast
    flight = nil, -- the query waiting for its reply
    sending = false, -- true while the addon itself calls SendWho
    off = {}, -- [trigger] = true once WoW refused a query sent from it
    warned = false,
}
ns.lookup = lookup

-- Key presses (a keyboard frame that passes every key on) and clicks in the game world. Both
-- are hardware events, which /who requires; WoWForeverRace uses the same two on this client.
local TRIGGERS = { "key", "world" }

-- Modifier keys are skipped: holding Shift to shift-click a name must not send a query of the
-- addon's own just before Blizzard's.
local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true }

-- Frames that show /who results. While the addon's query is out they stop listening and the
-- reply comes to the addon alone as WHO_LIST_UPDATE, so no window opens and nothing reaches chat.
local WHO_LIST_FRAMES = { "LFGWhoListFrame" } -- the Group Finder's Who tab; Forever's Friends frame has none

local function InsertQueued(item)
    local queue = lookup.queue
    local position = #queue + 1
    if item.urgent then
        position = 1
        while queue[position] and queue[position].urgent do
            position = position + 1
        end
    end
    tinsert(queue, position, item)
end

local function UnmarkTried(key)
    if lookup.tried[key] then
        lookup.tried[key] = nil
        lookup.triedCount = lookup.triedCount - 1
    end
end

-- Queues a /who for a sender, whispers ahead of everyone else.
local function QueueLookup(name, key, urgent)
    if (lookup.flight and lookup.flight.key == key) or lookup.tried[key] then
        return
    end
    local queue = lookup.queue
    if lookup.queued[key] then
        -- A whisper from someone already waiting behind channel speakers moves them up.
        if urgent then
            for index, item in ipairs(queue) do
                if item.key == key and not item.urgent then
                    tremove(queue, index)
                    item.urgent = true
                    InsertQueued(item)
                    break
                end
            end
        end
        return
    end
    if #queue >= LOOKUP_QUEUE_MAX then
        if not urgent or queue[#queue].urgent then
            return
        end
        lookup.queued[tremove(queue).key] = nil
    end
    InsertQueued({ name = name, key = key, urgent = urgent })
    lookup.queued[key] = true
    if #queue == 1 then
        UpdateKeyWatch()
    end
end
ns.QueueLookup = QueueLookup

local function WhoPanelOpen()
    return LFGWhoListFrame and LFGWhoListFrame:IsVisible()
end

local function WhoDisabled()
    local rule = Enum and Enum.GameRule and Enum.GameRule.IngameWhoListDisabled
    return rule and C_GameRules and C_GameRules.IsGameRuleActive and C_GameRules.IsGameRuleActive(rule)
end

-- During the client's chat security lockdown system lines never reach addon filters, so a reply
-- could be neither read nor hidden.
local function ChatLockdown()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

-- Whether the addon can look anyone up at all right now.
local function LookupsPossible()
    if not settings.enabled or not settings.lookup or WhoDisabled() then
        return false
    end
    for _, trigger in ipairs(TRIGGERS) do
        if not lookup.off[trigger] then
            return true
        end
    end
    return false
end
ns.LookupsPossible = LookupsPossible

local function SuppressWhoUi(flight)
    flight.suppressed = {}
    for _, name in ipairs(WHO_LIST_FRAMES) do
        local frame = _G[name]
        if frame and frame.IsEventRegistered and frame:IsEventRegistered("WHO_LIST_UPDATE") then
            frame:UnregisterEvent("WHO_LIST_UPDATE")
            flight.suppressed[#flight.suppressed + 1] = frame
        end
    end
    if C_FriendList.SetWhoToUi then
        C_FriendList.SetWhoToUi(true)
    end
end

-- Hands /who back to Blizzard: the frames listen again and short results go to chat.
local function RestoreWhoUi(flight)
    if not flight or not flight.suppressed then
        return
    end
    for _, frame in ipairs(flight.suppressed) do
        frame:RegisterEvent("WHO_LIST_UPDATE")
    end
    flight.suppressed = nil
    if not WhoPanelOpen() and C_FriendList.SetWhoToUi then
        C_FriendList.SetWhoToUi(false)
    end
end

local function SwitchOff(trigger)
    lookup.off[trigger] = true
    UpdateKeyWatch()
    if LookupsPossible() then
        return
    end
    if not lookup.warned then
        lookup.warned = true
        Print("WoW is not accepting the addon's /who lookups, so players it has not seen yet stay visible."
            .. " Shift-click a name, target or mouse over the player and their lines disappear.")
    end
end

local function Announce(flight)
    local guild = ns.GuildOfKey(flight.key)
    if guild == nil then
        Print(flight.name .. " did not show up in /who (offline, or not on your faction).")
    elseif guild == "" then
        Print(flight.name .. " is not in a guild.")
    else
        Print(flight.name .. " is in <" .. guild .. ">" .. (ns.GuildMatches(guild) and ", so their chat is hidden." or "."))
    end
end

-- Ends the query in flight. outcome is "answered", "lost" (no reply in time), "void" (refused,
-- or sent into a chat lockdown) or "yielded" (the player sent their own /who about the same
-- person).
local function FinishLookup(outcome)
    local flight = lookup.flight
    if not flight then
        return
    end
    lookup.flight = nil
    RestoreWhoUi(flight)
    if not active then
        C_Timer.After(0, ns.UpdateFilters) -- after the reply's count line has been through
    end
    if outcome == "yielded" then
        -- The player asked /who about the same person themselves; their reply shows as usual and
        -- teaches the addon too.
        return
    end
    if outcome ~= "answered" then
        -- A reply may still come after the timeout; keep it out of chat for a while.
        local key = flight.key
        lookup.recent[key] = GetTime() + LATE_REPLY_WINDOW
        C_Timer.After(LATE_REPLY_WINDOW, function()
            if lookup.recent[key] and GetTime() >= lookup.recent[key] then
                lookup.recent[key] = nil
            end
            ns.UpdateFilters()
        end)
    end
    if outcome == "answered" then
        lookup.interval = LOOKUP_INTERVAL
        if flight.announce then
            Announce(flight)
        end
        return
    end
    if outcome == "lost" then
        -- The server drops /who that comes too fast; slow down for a while.
        lookup.interval = math.min(lookup.interval * 2, LOOKUP_INTERVAL_MAX)
    end
    if flight.retried then
        if flight.announce then
            Print("No /who reply for " .. flight.name .. ".")
        end
        return
    end
    -- One more try.
    UnmarkTried(flight.key)
    QueueLookup(flight.name, flight.key, flight.urgent)
    for _, item in ipairs(lookup.queue) do
        if item.key == flight.key then
            item.retried, item.announce = true, flight.announce
        end
    end
end
ns.FinishLookup = FinishLookup

-- Sends the next queued /who. Runs inside a key press or a click, which WoW requires.
local function TryLookup(trigger)
    if lookup.off[trigger] or lookup.flight then
        return
    end
    local queue = lookup.queue
    if #queue == 0 or GetTime() - lookup.lastSent < lookup.interval then
        return
    end
    if InCombatLockdown() or WhoPanelOpen() or WhoDisabled() or ChatLockdown() then
        return
    end
    local item
    repeat
        item = tremove(queue, 1)
        if item then
            lookup.queued[item.key] = nil
        end
    until not item or item.announce or (settings.enabled and settings.lookup and ns.GuildOfKey(item.key) == nil)
    if not queue[1] then
        UpdateKeyWatch()
    end
    if not item then
        return
    end
    if not lookup.tried[item.key] then
        -- Players /who never finds pile up here; starting over costs at most one more query each.
        if lookup.triedCount >= TRIED_MAX then
            lookup.tried, lookup.triedCount = {}, 0
        end
        lookup.tried[item.key] = true
        lookup.triedCount = lookup.triedCount + 1
    end
    local flight = {
        name = item.name,
        key = item.key,
        urgent = item.urgent,
        retried = item.retried,
        announce = item.announce,
        trigger = trigger,
        sentAt = GetTime(),
    }
    lookup.flight = flight
    lookup.lastSent = flight.sentAt
    stats.lookups = stats.lookups + 1
    if not active then
        ns.UpdateFilters() -- the reply's system lines still need the filter
    end
    SuppressWhoUi(flight)
    -- The query Blizzard sends when a name in chat is shift-clicked.
    local query = type(WHO_TAG_EXACT) == "string" and (WHO_TAG_EXACT .. item.name) or ('n-"' .. item.name .. '"')
    local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Item
    lookup.sending = true
    local ok = pcall(C_FriendList.SendWho, query, origin)
    lookup.sending = false
    if not ok then
        FinishLookup("void")
        return
    end
    C_Timer.After(LOOKUP_TIMEOUT, function()
        if lookup.flight == flight then
            if flight.answered then
                FinishLookup("answered")
            else
                FinishLookup(ChatLockdown() and "void" or "lost")
            end
        end
    end)
end
ns.TryLookup = TryLookup

-- A /who of the player's own (a shift-click, the Who list, another addon) while the addon's is
-- out: hand the Who list back at once so that reply shows as usual, and stop trusting an empty
-- result, which could be theirs.
if hooksecurefunc and C_FriendList and C_FriendList.SendWho then
    hooksecurefunc(C_FriendList, "SendWho", function(query)
        if lookup.sending then
            return
        end
        local flight = lookup.flight
        if not flight then
            -- Leave the player's own reply to Blizzard: no query of the addon's right behind it.
            lookup.lastSent = GetTime()
            return
        end
        flight.foreign = true
        RestoreWhoUi(flight)
        local name = type(query) == "string" and Readable(query) and query:match('^%a%-"?([^"]+)"?$')
        if name and KeyOf(name) == flight.key then
            lookup.recent[flight.key] = nil
            FinishLookup("yielded") -- also re-checks the filters when hiding is off
        end
    end)
end

-- /who replies ------------------------------------------------------------------------------------

local parseGuildLine, parsePlainLine, countOf

local function BuildWhoParsers()
    parseGuildLine = Match.WhoLineParser(WHO_LIST_GUILD_FORMAT)
    parsePlainLine = Match.WhoLineParser(WHO_LIST_FORMAT)
    countOf = Match.CountLineMatcher(WHO_NUM_RESULTS)
end
ns.BuildWhoParsers = BuildWhoParsers

-- Learns from a system line (the reply to a shift-click or a short /who of the player's own, or
-- the addon's reply if the client printed it after all). Returns true for lines that answer the
-- addon's own queries.
local function HandleSystemLine(text)
    local flight = lookup.flight
    local now = GetTime()
    local name, guild
    if parseGuildLine then
        name, guild = parseGuildLine(text)
    end
    -- A guild line also fits the guildless format (the guild lands in the class field), so the
    -- guildless parse only runs when the guild parse exists and failed.
    if not name and parseGuildLine and parsePlainLine then
        name, guild = parsePlainLine(text)
    end
    local key = name and KeyOf(name)
    if not key and flight then
        -- The client's format may differ from the global strings; accept a looser parse, but only
        -- for the player the addon asked about.
        name, guild = Match.LooseWhoLine(text)
        key = name and KeyOf(name)
        if key ~= flight.key then
            key = nil
        end
    end
    if key then
        Remember(key, guild)
        if flight and key == flight.key then
            flight.answered = true
            return true
        end
        local lateUntil = lookup.recent[key]
        if lateUntil and now <= lateUntil then
            -- The reply to a query that already timed out; its count line follows. The filter is
            -- re-checked later, never from inside the filter call Blizzard is iterating.
            lookup.recent[key] = nil
            lookup.lateCountUntil = now + 2
            if not active then
                C_Timer.After(3, ns.UpdateFilters)
            end
            return true
        end
        return false
    end
    local count = countOf and countOf(text)
    if count then
        if count == 1 and lookup.lateCountUntil and now <= lookup.lateCountUntil then
            lookup.lateCountUntil = nil
            return true
        end
        -- A count line belongs to the addon's query only if it fits: 1 after its name line, or 0
        -- with none (and no /who of the player's own out). Anything else answers theirs.
        if flight and ((flight.answered and count == 1) or (not flight.answered and count == 0 and not flight.foreign)) then
            FinishLookup("answered")
            return true
        end
    end
    return false
end
ns.HandleSystemLine = HandleSystemLine

local function HarvestWhoList()
    local flight = lookup.flight
    local count = C_FriendList.GetNumWhoResults() or 0
    local ours = false
    for i = 1, count do
        local info = C_FriendList.GetWhoInfo(i)
        if type(info) == "table" and Readable(info.fullName) and Readable(info.fullGuildName) then
            local key = KeyOf(info.fullName)
            Remember(key, info.fullGuildName or "")
            ours = ours or (flight ~= nil and key == flight.key)
        end
    end
    -- The addon's reply holds the player it asked about, or nobody (offline or the other
    -- faction) when no /who of the player's own is out.
    if flight and (ours or (count == 0 and not flight.foreign)) then
        FinishLookup("answered")
    end
end

-- Chat filters ------------------------------------------------------------------------------------

local channelKeys = {} -- [channel name as sent] = channel key; a handful of channels

-- Whether a chat event from a matching player should be hidden. allowLookup queues a /who for a
-- sender whose guild is unknown. The arguments after it are the event's own (arg1 to arg14).
-- Returns hide, and for a sender whose guild is unknown, their key.
Evaluate = function(event, allowLookup, _, author, _, _, _, _, _, _, channelBaseName, _, lineID, guid, bnSenderID)
    local category = categoryOfEvent[event]
    if not active or not category or settings.shown[category] then
        return false
    end
    if category == "channel" and type(channelBaseName) == "string" then
        local channel = channelKeys[channelBaseName]
        if channel == nil then
            channel = Match.ChannelKey(channelBaseName) or false
            channelKeys[channelBaseName] = channel
        end
        if channel and settings.shownChannels[channel] then
            return false
        end
    end
    if OWN_GUILD_EVENTS[event] then
        if IsMe(KeyOf(author), guid) then
            return false
        end
        return ns.GuildMatches((GetGuildInfo("player"))) ~= nil
    end
    local key
    if BNET_EVENTS[event] then
        -- The character the friend was on when the line was shown, if noted then; else the current one.
        local recorded = Readable(lineID) and bnLineKeys[lineID]
        if recorded then
            key, guid = recorded, nil
        else
            key, guid = BNetCharacter(bnSenderID)
        end
        allowLookup = false
    else
        key = KeyOf(author)
    end
    if not key or IsMe(key, guid) then
        return false
    end
    local guild = GuildOf(key, guid)
    if guild == nil then
        if BNET_EVENTS[event] then
            return false, key
        end
        -- Battle.net community senders carry a |K...|k token, not a character name.
        if author:find("|", 1, true) then
            return false
        end
        if allowLookup and settings.lookup then
            QueueLookup(author, key, category == "whisper")
        end
        return false, key
    end
    return ns.GuildMatches(guild) ~= nil
end
ns.Evaluate = Evaluate

-- A filter runs once per chat window that shows the event; lineID keeps them in step.
local memoLine, memoEvent, memoHide

local function ChatFilter(_, event, ...)
    local lineID = select(11, ...)
    if lineID and lineID ~= 0 and lineID == memoLine and event == memoEvent then
        return memoHide
    end
    local hide, unknownKey = Evaluate(event, true, ...)
    memoLine, memoEvent, memoHide = lineID, event, hide
    if unknownKey and BNET_EVENTS[event] and lineID and lineID ~= 0 then
        NoteBNetLine(lineID, unknownKey)
    end
    if hide then
        stats.hidden = stats.hidden + 1
        if ns.HideBubble then
            ns.HideBubble(event, (...))
        end
    elseif unknownKey then
        -- Shown for now; removed later if the guild turns out to match.
        NoteUnresolved(unknownKey)
    end
    return hide
end
ns.ChatFilter = ChatFilter

local systemMemoText, systemMemoTime, systemMemoHide

local BAR, ZERO, NINE = string.byte("|"), string.byte("0"), string.byte("9")

local function SystemFilter(_, _, text)
    -- /who replies start with a player link or a number; every other system line leaves at once.
    local first = type(text) == "string" and text:byte(1)
    if first ~= BAR and not (first and first >= ZERO and first <= NINE) then
        return false
    end
    local now = GetTime()
    if text == systemMemoText and now == systemMemoTime then
        return systemMemoHide
    end
    local hide = HandleSystemLine(text)
    systemMemoText, systemMemoTime, systemMemoHide = text, now, hide
    return hide
end
ns.SystemFilter = SystemFilter

-- Blizzard wraps every registered filter call in a secure call and packs its arguments, so only
-- the chat types being hidden get a filter, and none at all while hiding is off.
local filtered = {} -- [event] = true while ChatFilter is registered for it

local function UpdateFilters()
    local add, remove = ChatFrameUtil.AddMessageEventFilter, ChatFrameUtil.RemoveMessageEventFilter
    for event, category in pairs(categoryOfEvent) do
        local want = active and not settings.shown[category]
        if want and not filtered[event] then
            add(event, ChatFilter)
            filtered[event] = true
        elseif not want and filtered[event] then
            remove(event, ChatFilter)
            filtered[event] = nil
        end
    end
    -- /who replies: while hiding is on, and while one of the addon's own queries (or the window
    -- for its late reply) is out, such as /gmute check with hiding off.
    local wantSystem = active or lookup.flight ~= nil or next(lookup.recent) ~= nil
    if wantSystem and not filtered.CHAT_MSG_SYSTEM then
        add("CHAT_MSG_SYSTEM", SystemFilter)
        filtered.CHAT_MSG_SYSTEM = true
    elseif not wantSystem and filtered.CHAT_MSG_SYSTEM then
        remove("CHAT_MSG_SYSTEM", SystemFilter)
        filtered.CHAT_MSG_SYSTEM = nil
    end
end
ns.UpdateFilters = UpdateFilters

-- Settings ----------------------------------------------------------------------------------------

-- Copies well-formed values from src into the live settings table (ns.settings stays the same
-- table, so the options panel and Store keep their reference).
local function ApplySettings(src)
    for key, default in pairs(Store.Defaults()) do
        local value = src and src[key]
        if type(value) ~= type(default) then
            value = default
        end
        settings[key] = value
    end
end

local function ReportSave(ok, reason)
    if ok then
        return
    end
    if reason == "too long" then
        Print("One entry is too long to keep in a macro (255 characters)."
            .. " These settings work until you log out; shorten that entry to keep them.")
    elseif reason == "macro error" then
        Print("WoW refused to save the settings macro. These settings work until you log out.")
    else
        Print("No free macro slot to keep settings in. They work until you log out.")
    end
end

-- Key presses and clicks that may carry a queued /who ----------------------------------------------

-- The key watcher is only shown while a lookup is queued, so an idle addon costs nothing per key
-- press. Blizzard's InsecureKeyboardInputPropagatorTemplate ("for use by addons") passes every key
-- on to the game from XML, so no restricted call is needed and it works from the first key, even
-- after a /reload in combat. Showing and hiding it is allowed in combat: it is not protected.
local keyWatcher = CreateFrame("Frame", nil, UIParent, "InsecureKeyboardInputPropagatorTemplate")
keyWatcher:SetSize(1, 1)
keyWatcher:SetPoint("TOPLEFT")
keyWatcher:EnableKeyboard(true)
keyWatcher:Hide()
keyWatcher:SetScript("OnKeyDown", function(_, key)
    if not MODIFIER_KEYS[key] then
        TryLookup("key")
    end
end)

UpdateKeyWatch = function()
    keyWatcher:SetShown(not lookup.off.key and #lookup.queue > 0)
end

-- Clicks in the game world: a script hook on WorldFrame runs inside the click itself, and returns
-- at once when nothing is queued.
if WorldFrame and WorldFrame.HookScript then
    WorldFrame:HookScript("OnMouseDown", function()
        if lookup.queue[1] then
            TryLookup("world")
        end
    end)
end

local BUTTON_GRACE = 5 -- seconds without any macro before the minimap button takes its default spot
local buttonPlaced = false

-- The first read of the settings macro places the minimap button, so a moved or hidden button
-- does not flash at its default spot on login.
local function ReadStoredSettings()
    Store.Read()
    if ns.UpdateMinimapButton then
        ns.UpdateMinimapButton()
    end
end

-- After /reload the macros are already here; on a fresh login they arrive a little later
-- (UPDATE_MACROS). Poll once a second meanwhile, and read anyway after Store.MACRO_WAIT seconds.
-- Changes made before the read are merged, not lost.
function WaitForMacros(deadline)
    if Store.IsReady() then
        return
    end
    local numAccount, numCharacter = GetNumMacros()
    if (numAccount or 0) + (numCharacter or 0) > 0 or GetTime() >= deadline then
        ReadStoredSettings()
    else
        -- Still no macros a few seconds in: most likely there are none, and the defaults are what a
        -- read would give. Place the button now rather than after the whole wait (a stored macro,
        -- if one arrives, still wins). Anyone who moved or hid it has a macro, which usually
        -- arrives within the grace.
        if not buttonPlaced and ns.UpdateMinimapButton and GetTime() >= deadline - Store.MACRO_WAIT + BUTTON_GRACE then
            buttonPlaced = true
            ns.UpdateMinimapButton()
        end
        C_Timer.After(1, function()
            WaitForMacros(deadline)
        end)
    end
end

-- The Communities window --------------------------------------------------------------------------

-- The Communities window shows club chat straight from the server, without chat filters. Its
-- lines carry the club, stream and message id, which lead back to the author.
local guildClubs = {} -- [clubId] = whether the club is the player's guild; clubs keep their type

local function IsGuildClub(clubId)
    local isGuild = guildClubs[clubId]
    if isGuild ~= nil then
        return isGuild
    end
    -- Club info can be missing before the client has it, and secret in a chat lockdown; only a
    -- definite answer is remembered.
    local club = C_Club and C_Club.GetClubInfo and C_Club.GetClubInfo(clubId)
    if not ReadableTable(club) or not Readable(club.clubType) or club.clubType == nil then
        return false
    end
    isGuild = Enum and Enum.ClubType and club.clubType == Enum.ClubType.Guild or false
    guildClubs[clubId] = isGuild
    return isGuild
end

local function CommunityMessageHidden(clubId, message, only)
    if not active or settings.shown.community or not ReadableTable(message)
        or not Readable(clubId) or clubId == nil then
        return false
    end
    local author = message.author
    if not ReadableTable(author) or not Readable(author.isSelf) or author.isSelf then
        return false
    end
    local name = author.name
    local key = Readable(name) and type(name) == "string" and not name:find("|", 1, true) and KeyOf(name)
    if only and not (key and only[key]) then
        return false -- a pass for other senders
    end
    if IsGuildClub(clubId) then
        -- The guild's own streams: every author is in the player's guild.
        return ns.GuildMatches((GetGuildInfo("player"))) ~= nil
    end
    if not key or IsMe(key, author.guid) then
        return false -- Battle.net communities show account names, not characters
    end
    local guild = GuildOf(key, Readable(author.guid) and author.guid or nil)
    if guild == nil then
        NoteUnresolved(key)
        if settings.lookup then
            QueueLookup(name, key, false)
        end
        return false
    end
    return ns.GuildMatches(guild) ~= nil
end

local communitiesHooked = false

function HookCommunities()
    local chat = CommunitiesFrame and CommunitiesFrame.Chat
    if communitiesHooked or not chat or not chat.MessageFrame then
        return
    end
    communitiesHooked = true
    -- History arrives a hundred messages at a time, so removals are gathered and done in one pass
    -- on the next frame.
    local pending, scheduled = {}, false
    local function RemovePending()
        scheduled = false
        local ids = pending
        pending = {}
        chat.MessageFrame:RemoveMessagesByPredicate(function(_, _, _, _, _, _, messageId)
            return ids[messageId] == true
        end)
    end
    hooksecurefunc(chat, "AddMessage", function(_, clubId, _, message)
        if CommunityMessageHidden(clubId, message) then
            pending[message.messageId] = true
            if not scheduled then
                scheduled = true
                C_Timer.After(0, RemovePending)
            end
        end
    end)
end

-- Removal pass for the Communities window: every line, or only those by the senders in `only`.
-- A closed window is skipped: opening it re-adds every line through the hooked AddMessage.
function ns.PurgeCommunities(only)
    local frame = communitiesHooked and CommunitiesFrame.Chat.MessageFrame
    if not frame or not CommunitiesFrame.Chat:IsVisible() or not (C_Club and C_Club.GetMessageInfo) then
        return
    end
    frame:RemoveMessagesByPredicate(function(_, _, _, _, clubId, streamId, messageId)
        if clubId == nil or streamId == nil or type(messageId) ~= "table" then
            return false
        end
        return CommunityMessageHidden(clubId, C_Club.GetMessageInfo(clubId, streamId, messageId), only)
    end)
end

-- Events ------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
local handlers = {}

-- Events the addon always needs, and the ones it only listens to while hiding is on.
local CORE_EVENTS = {
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "UPDATE_MACROS", "PLAYER_REGEN_ENABLED",
    "WHO_LIST_UPDATE", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
}
local WORK_EVENTS = {
    "PLAYER_GUILD_UPDATE", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_FOCUS_CHANGED",
    "NAME_PLATE_UNIT_ADDED", "GROUP_ROSTER_UPDATE", "PLAYER_SOFT_FRIEND_CHANGED",
    "PLAYER_SOFT_ENEMY_CHANGED", "CLUB_MEMBER_UPDATED",
}

local function Listen(list, on)
    for _, event in ipairs(list) do
        -- Tolerate an event this client build does not have.
        pcall(on and events.RegisterEvent or events.UnregisterEvent, events, event)
    end
end

-- Turns the addon's work on or off to match the settings: chat filters, unit events, key watch.
local listening = nil -- whether WORK_EVENTS are registered
local function UpdateActivity()
    active = settings.enabled and #phrases > 0
    UpdateFilters()
    if active ~= listening then
        Listen(WORK_EVENTS, active)
        listening = active
    end
    if not active then
        lookup.queue, lookup.queued = {}, {}
    end
    UpdateKeyWatch()
end

-- Call after changing ns.settings. save=false when the change came from the stored macro.
function ns.SettingsChanged(save)
    CompilePhrases()
    UpdateActivity()
    memoLine = nil
    SchedulePurge(nil)
    if save then
        ReportSave(Store.Save())
    end
    if ns.RefreshOptions then
        ns.RefreshOptions()
    end
    if ns.UpdateMinimapButton then
        ns.UpdateMinimapButton()
    end
end

-- Saves without re-applying anything, for changes like the minimap button's place.
function ns.SaveSettings()
    ReportSave(Store.Save())
end

Store.Init(function(stored)
    ApplySettings(stored)
    ns.SettingsChanged(false)
end)

function ns.KnownCounts()
    if not matchingCount then
        matchingCount = 0
        for _, guild in pairs(guilds) do
            if ns.GuildMatches(guild) then
                matchingCount = matchingCount + 1
            end
        end
    end
    return knownCount, matchingCount
end

-- Stamps everyone confirmed this session with today, for SavedVariables (once Blizzard loads them).
local function StampSeen()
    local today = Today()
    for key in pairs(guilds) do
        if seenDay[key] == nil then
            seenDay[key] = today
        end
    end
end

function ns.ForgetGuilds()
    for key in pairs(guilds) do
        guilds[key], seenDay[key] = nil, nil
    end
    knownCount, matchingCount = 0, 0
    lookup.tried, lookup.triedCount = {}, 0
end

function handlers.ADDON_LOADED(name)
    if name == "Blizzard_Communities" then
        HookCommunities()
        return
    end
    if name ~= ADDON_NAME then
        return
    end
    local db = type(GuildMuteDB) == "table" and GuildMuteDB or {}
    GuildMuteDB = db
    ApplySettings(db.settings)
    Store.SetBaseline(settings)
    db.settings = settings
    db.guilds, db.seenDay = LoadGuilds(type(db.guilds) == "table" and db.guilds or {},
        type(db.seenDay) == "table" and db.seenDay or {})
    CompilePhrases()
    UpdateActivity()
end

function handlers.PLAYER_LOGIN()
    -- A /reload in the middle of a lookup could leave /who results routed to the Who list.
    if C_FriendList.SetWhoToUi and not WhoPanelOpen() then
        C_FriendList.SetWhoToUi(false)
    end
    homeRealm = GetNormalizedRealmName and GetNormalizedRealmName() or homeRealm
    myKey, myGUID = KeyOf(UnitName("player")), UnitGUID("player")
    BuildWhoParsers()
    ObserveGroup()
    WaitForMacros(GetTime() + Store.MACRO_WAIT)
    HookCommunities()
end

function handlers.UPDATE_MACROS()
    ReadStoredSettings()
end

function handlers.PLAYER_REGEN_ENABLED()
    -- A settings write that waited for combat to end; usually nothing.
    ReportSave(Store.OnCombatEnd())
end

function handlers.PLAYER_GUILD_UPDATE(unit)
    if unit == nil or unit == "player" then
        SchedulePurge(nil) -- the player's own guild just became known or changed
    else
        ObserveUnit(unit, true)
    end
end

function handlers.PLAYER_TARGET_CHANGED()
    ObserveUnit("target", false)
    ObserveUnit("targettarget", false)
end

function handlers.UPDATE_MOUSEOVER_UNIT()
    ObserveUnit("mouseover", false)
end

function handlers.PLAYER_FOCUS_CHANGED()
    ObserveUnit("focus", false)
end

function handlers.NAME_PLATE_UNIT_ADDED(unit)
    ObserveUnit(unit, false)
end

function handlers.PLAYER_SOFT_FRIEND_CHANGED()
    ObserveUnit("softfriend", false)
end

function handlers.PLAYER_SOFT_ENEMY_CHANGED()
    ObserveUnit("softenemy", false)
end

-- Raids fire GROUP_ROSTER_UPDATE in bursts; one look at the group a second later covers them.
local groupScanPending = false
function handlers.GROUP_ROSTER_UPDATE()
    if not groupScanPending then
        groupScanPending = true
        C_Timer.After(1, function()
            groupScanPending = false
            ObserveGroup()
        end)
    end
end

-- A community author's name can arrive after their lines. Club members update all the time, so
-- only an open Communities window is looked at again, at most once a second.
local communitiesCheckPending = false
function handlers.CLUB_MEMBER_UPDATED()
    if communitiesHooked and not communitiesCheckPending and CommunitiesFrame:IsShown() then
        communitiesCheckPending = true
        C_Timer.After(1, function()
            communitiesCheckPending = false
            ns.PurgeCommunities(nil)
        end)
    end
end

handlers.WHO_LIST_UPDATE = HarvestWhoList
handlers.PLAYER_LOGOUT = StampSeen

-- A refused /who shows "Interface action failed because of an AddOn" once per session.
-- Stop using the trigger that caused it.
local function ActionRefused(addon)
    local flight = lookup.flight
    if addon == ADDON_NAME and flight and GetTime() - flight.sentAt < 1 then
        SwitchOff(flight.trigger)
        FinishLookup("void")
    end
end
handlers.ADDON_ACTION_BLOCKED = ActionRefused
handlers.ADDON_ACTION_FORBIDDEN = ActionRefused

events:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)
Listen(CORE_EVENTS, true)

-- Slash commands ----------------------------------------------------------------------------------

local function SplitRaw(text)
    local parts = {}
    for part in (text or ""):gsub("\n", ","):gmatch("[^,]+") do
        part = part:match("^%s*(.-)%s*$")
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return parts
end

function ns.AddPhrase(phrase)
    local parts = SplitRaw(settings.phrases)
    local folded = Match.Fold(phrase)
    for _, part in ipairs(parts) do
        if Match.Fold(part) == folded then
            return false
        end
    end
    parts[#parts + 1] = phrase
    settings.phrases = table.concat(parts, ", ")
    ns.SettingsChanged(true)
    return true
end

function ns.RemovePhrase(phrase)
    local folded, kept, removed = Match.Fold(phrase), {}, false
    for _, part in ipairs(SplitRaw(settings.phrases)) do
        if Match.Fold(part) == folded then
            removed = true
        else
            kept[#kept + 1] = part
        end
    end
    if removed then
        settings.phrases = table.concat(kept, ", ")
        ns.SettingsChanged(true)
    end
    return removed
end

local function PrintStatus()
    local list = table.concat(SplitRaw(settings.phrases), ", ")
    Print((settings.enabled and "On" or "Off") .. ". Hiding chat from guilds containing: "
        .. (list ~= "" and list or "(nothing)") .. (settings.typo and (" (one typo allowed in phrases of " .. Match.TYPO_MIN_LENGTH .. "+ letters)") or ""))
    local known, matching = ns.KnownCounts()
    Print(("Hidden %d lines this session. Guilds known for %d players, %d of them matching. %d /who lookups sent%s.")
        :format(stats.hidden, known, matching, stats.lookups, settings.lookup and "" or ", lookups are off"))
    if lookup.off.key and lookup.off.world then
        Print("WoW refused the addon's /who lookups this session.")
    end
    if Store.HasMacro() then
        Print("Settings are kept in the GuildMute macro (General tab), since this client does not load saved settings.")
    end
    if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
        UpdateAddOnMemoryUsage()
        Print(("Memory in use: %.0f KB."):format(GetAddOnMemoryUsage(ADDON_NAME)))
    end
end

local function PrintHelp()
    Print("commands:")
    print("  /gmute               open the settings")
    print("  /gmute add <words>   hide guilds whose name contains these words")
    print("  /gmute remove <words>")
    print("  /gmute on | off      turn hiding on or off")
    print("  /gmute test <guild>  check whether a guild name would be hidden")
    print("  /gmute check <name>  look up a player's guild with /who")
    print("  /gmute status        what is hidden and what the addon knows")
    print("  /gmute forget        forget the guilds it has learned")
    print("  /gmute minimap       show or hide the minimap button")
end

SLASH_GUILDMUTE1 = "/gmute"
SLASH_GUILDMUTE2 = "/guildmute"
SlashCmdList.GUILDMUTE = function(message)
    local command, rest = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    if command == "" then
        if ns.OpenOptions then
            ns.OpenOptions()
        else
            PrintStatus()
        end
    elseif command == "add" and rest ~= "" then
        if ns.AddPhrase(rest) then
            Print("Now hiding chat from guilds containing \"" .. rest .. "\".")
        else
            Print("\"" .. rest .. "\" is already on the list.")
        end
    elseif command == "remove" and rest ~= "" then
        if ns.RemovePhrase(rest) then
            Print("Removed \"" .. rest .. "\". Lines hidden earlier stay hidden.")
        else
            Print("\"" .. rest .. "\" is not on the list.")
        end
    elseif command == "on" or command == "off" then
        settings.enabled = command == "on"
        ns.SettingsChanged(true)
        PrintStatus()
    elseif command == "test" and rest ~= "" then
        local phrase, typo = Match.FindPhrase(rest, phrases, settings.typo)
        if phrase then
            Print("<" .. rest .. "> matches \"" .. phrase .. "\"" .. (typo and " (with one typo)" or "") .. ", so its members are hidden.")
        else
            Print("<" .. rest .. "> does not match, so its members are shown.")
        end
    elseif command == "check" and rest ~= "" then
        local key = KeyOf(rest)
        if not key then
            Print("Usage: /gmute check <name> or <name-realm>")
            return
        end
        UnmarkTried(key)
        lookup.queued[key] = nil
        for index, item in ipairs(lookup.queue) do
            if item.key == key then
                tremove(lookup.queue, index)
                break
            end
        end
        tinsert(lookup.queue, 1, { name = rest, key = key, urgent = true, announce = true })
        lookup.queued[key] = true
        UpdateKeyWatch()
        -- Typing the command was a key press, so the query can go out right away when allowed.
        local sent = stats.lookups
        TryLookup("slash")
        if stats.lookups == sent then
            Print("Looking up " .. rest .. " with your next key press or click.")
        end
    elseif command == "status" then
        PrintStatus()
    elseif command == "minimap" then
        settings.minimap = not settings.minimap
        ns.SaveSettings()
        ns.UpdateMinimapButton()
        ns.RefreshOptions()
        Print(settings.minimap and "Minimap button shown." or "Minimap button hidden; /gmute minimap brings it back.")
    elseif command == "forget" then
        ns.ForgetGuilds()
        Print("Forgot every learned guild.")
    else
        PrintHelp()
    end
end

-- Addon compartment (the addons button by the minimap).
function GuildMute_OnAddonCompartmentClick()
    SlashCmdList.GUILDMUTE("")
end
