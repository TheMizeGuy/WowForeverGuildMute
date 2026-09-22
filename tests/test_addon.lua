-- The whole addon under the fake client in tests/wow.lua: chat filtering, guild learning,
-- /who lookups, removal of earlier lines, macro-kept settings, combat, refusals and the
-- settings page.

local T = dofile("tests/t.lua")
local wow = dofile("tests/wow.lua")

local ZEUS = { name = "Zeus", guild = "Olympus VI", guid = "Player-1-ZEUS" }

local function SeeZeus(guild)
    wow.units.nameplate1 = { name = ZEUS.name, guild = guild or ZEUS.guild, guid = ZEUS.guid }
    wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
end

local function WhoReply(name, guild)
    local shown = wow.System(wow.WhoLine(name, guild))
    local countShown = wow.System("1 player total")
    return shown, countShown
end

local function Slash(text)
    SlashCmdList.GUILDMUTE(text)
end

T.test("defaults hide Olympus in every chat type, with nothing saved", function()
    local ns = wow.Load()
    T.eq(ns.settings.phrases, "Olympus")
    SeeZeus()
    for _, category in ipairs(ns.CATEGORIES) do
        for _, event in ipairs(category.events) do
            if event ~= "CHAT_MSG_GUILD" and event ~= "CHAT_MSG_OFFICER" and event ~= "CHAT_MSG_GUILD_ACHIEVEMENT"
                and event ~= "CHAT_MSG_BN_WHISPER" and event ~= "CHAT_MSG_BN_WHISPER_INFORM" then
                local shown = wow.Chat(event, { author = "Zeus-Forever", guid = ZEUS.guid, channel = event == "CHAT_MSG_CHANNEL" and "Trade - City" or nil })
                T.eq(shown, false, event)
            end
        end
    end
    T.eq(wow.macroWrites, 0, "defaults need no macro")
end)

T.test("case, numbering and one typo in the guild name all hide", function()
    for _, guild in ipairs({ "Olympus", "olympus", "Olympus VI", "Olypus VI" }) do
        wow.Load()
        SeeZeus(guild)
        T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Zeus", guid = ZEUS.guid }), false, guild)
    end
end)

T.test("other guilds, guildless players and yourself stay visible", function()
    wow.Load()
    wow.units.target = { name = "Ares", guild = "Titans", guid = "Player-1-ARES" }
    wow.Fire("PLAYER_TARGET_CHANGED")
    T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Ares", guid = "Player-1-ARES" }), true)
    wow.units.mouseover = { name = "Hermes", guid = "Player-1-HERMES" }
    wow.Fire("UPDATE_MOUSEOVER_UNIT")
    T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Hermes", guid = "Player-1-HERMES" }), true)
    wow.myGuild = "Olympus"
    T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Me-Forever", guid = "Player-1-ME" }), true, "your own lines")
end)

T.test("a visible sender's guild is read at message time through the GUID", function()
    wow.Load()
    wow.units.party1 = { name = "Zeus", guild = "Olympus", guid = ZEUS.guid }
    T.eq(wow.Chat("CHAT_MSG_PARTY", { author = "Zeus", guid = ZEUS.guid }), false)
end)

T.test("an unknown whisperer is looked up on the next key press and their whisper removed", function()
    local ns = wow.Load()
    T.eq(wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus-Forever", guid = ZEUS.guid, text = "join us" }), true,
        "the line from an unknown sender is shown")
    T.eq(wow.CountLines("[Zeus-Forever]: join us"), 1, "as it is, text and all")
    T.eq(#wow.whoQueries, 0, "no /who outside a key press")
    wow.KeyPress()
    T.same(wow.whoQueries, { "x-Zeus-Forever" }, "the shift-click query")
    local lineShown, countShown = WhoReply("Zeus-Forever", "Olympus VI")
    T.eq(lineShown, false, "the reply line to the addon's own query is hidden")
    T.eq(countShown, false, "and so is its count line")
    wow.Advance(0)
    T.eq(wow.CountLines("join us"), 0, "the earlier whisper is gone from the first window")
    T.eq(wow.CountLines("join us", 2), 0, "and from the second")
    T.eq(wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus-Forever", guid = ZEUS.guid, text = "hello?" }), false)
    T.eq(wow.Chat("CHAT_MSG_WHISPER_INFORM", { author = "Zeus-Forever", guid = ZEUS.guid, text = "no thanks" }), false,
        "your replies to them")
    T.eq(wow.Chat("CHAT_MSG_AFK", { author = "Zeus-Forever", guid = ZEUS.guid }), false, "their away message")
    T.eq(ns.stats.lookups, 1)
end)

T.test("an unknown whisperer outside the guild stays visible after the lookup", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Ares", guid = "Player-1-ARES", text = "hi there" })
    wow.KeyPress()
    WhoReply("Ares", "Titans")
    wow.Advance(0)
    T.eq(wow.CountLines("hi there"), 1)
    T.eq(wow.Chat("CHAT_MSG_WHISPER", { author = "Ares", guid = "Player-1-ARES" }), true)
end)

T.test("a /who you run yourself teaches the addon and stays in chat", function()
    local ns = wow.Load()
    T.eq(wow.System(wow.WhoLine("Zeus", "Olympus")), true, "your own /who result stays visible")
    T.eq(wow.System("1 player total"), true)
    T.eq(ns.GuildOfKey("zeus-forever"), "Olympus")
    T.eq(wow.Chat("CHAT_MSG_CHANNEL", { author = "Zeus", guid = ZEUS.guid, channel = "Trade - City" }), false)
    T.eq(#wow.whoQueries, 0)
end)

T.test("guildless /who replies are remembered so they are not asked again", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Hermes", guid = "Player-1-HERMES" })
    wow.KeyPress()
    WhoReply("Hermes", nil)
    T.eq(ns.GuildOfKey("hermes-forever"), "")
    wow.Advance(10)
    wow.Chat("CHAT_MSG_WHISPER", { author = "Hermes", guid = "Player-1-HERMES" })
    wow.KeyPress()
    T.eq(#wow.whoQueries, 1)
end)

T.test("whispers jump the lookup queue and lookups are spaced out", function()
    wow.Load()
    wow.Chat("CHAT_MSG_CHANNEL", { author = "Apollo", guid = "Player-1-A", channel = "Trade - City" })
    wow.Chat("CHAT_MSG_CHANNEL", { author = "Athena", guid = "Player-1-B", channel = "Trade - City" })
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    T.same(wow.whoQueries, { "x-Zeus" })
    WhoReply("Zeus", "Olympus")
    wow.KeyPress()
    T.eq(#wow.whoQueries, 1, "too soon after the last query")
    wow.Advance(5)
    wow.KeyPress()
    T.same(wow.whoQueries, { "x-Zeus", "x-Apollo" })
end)

T.test("clicks in the game world can carry a lookup too", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.WorldClick()
    T.same(wow.whoQueries, { "x-Zeus" })
end)

T.test("no lookups in combat, while the Who list is open or when switched off", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.combat = true
    wow.KeyPress()
    wow.combat = false
    LFGWhoListFrame.shown = true
    wow.KeyPress()
    LFGWhoListFrame.shown = false
    wow.lockdown = true
    wow.KeyPress()
    wow.lockdown = false
    T.eq(#wow.whoQueries, 0)
    ns.settings.lookup = false
    wow.KeyPress()
    T.eq(#wow.whoQueries, 0)
end)

T.test("a refused /who switches that trigger off and says so once both are off", function()
    local ns = wow.Load()
    wow.whoRefuses = true
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    T.ok(ns.lookup.off.key, "keyboard trigger off")
    T.ok(not wow.Printed("not accepting"), "no message while world clicks may still work")
    wow.Advance(5)
    wow.WorldClick()
    T.ok(ns.lookup.off.world, "world-click trigger off")
    T.ok(wow.Printed("not accepting"))
    T.eq(#wow.whoQueries, 2, "the name was retried through the other trigger")
    wow.Advance(5)
    wow.KeyPress()
    wow.WorldClick()
    T.eq(#wow.whoQueries, 2, "nothing more is sent")
    T.eq(wow.whoToUi, false, "the Who list was handed back")
    T.ok(LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))
end)

T.test("lost replies slow lookups down instead of switching them off", function()
    local ns = wow.Load()
    for _, name in ipairs({ "Zeus", "Hera", "Ares", "Apollo" }) do
        wow.Chat("CHAT_MSG_WHISPER", { author = name, guid = "Player-1-" .. name })
    end
    wow.KeyPress()
    wow.Advance(10)
    T.eq(ns.lookup.interval, 10)
    wow.KeyPress()
    T.eq(#wow.whoQueries, 2)
    wow.Advance(10)
    T.eq(ns.lookup.interval, 20)
    wow.Advance(20)
    wow.KeyPress()
    wow.Advance(10)
    T.eq(ns.lookup.interval, 30, "capped at 30 seconds")
    T.ok(not ns.lookup.off.key)
    wow.Advance(30)
    wow.KeyPress()
    WhoReply(wow.whoQueries[#wow.whoQueries]:sub(3), "Titans")
    T.eq(ns.lookup.interval, 5, "back to normal after an answer")
end)

T.test("silence never switches off a trigger that has worked", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    WhoReply("Zeus", "Olympus")
    for _, name in ipairs({ "Hera", "Ares", "Apollo", "Athena" }) do
        wow.Chat("CHAT_MSG_WHISPER", { author = name, guid = "Player-1-" .. name })
    end
    for _ = 1, 8 do
        wow.Advance(5)
        wow.KeyPress()
    end
    T.ok(not ns.lookup.off.key)
end)

T.test("a timeout during chat lockdown does not slow lookups down", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    wow.lockdown = true
    wow.Advance(10)
    T.eq(ns.lookup.interval, 5)
    T.eq(ns.lookup.queue[1] and ns.lookup.queue[1].key, "zeus-forever", "queued again for later")
end)

T.test("a zero-result reply counts as answered", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    T.eq(wow.System("0 players total"), false)
    T.eq(ns.lookup.flight, nil)
    T.eq(ns.lookup.interval, 5)
end)

T.test("a reply routed to the Who list is harvested", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    wow.whoResults = { { fullName = "Zeus", fullGuildName = "Olympus" } }
    wow.Fire("WHO_LIST_UPDATE")
    T.eq(ns.GuildOfKey("zeus-forever"), "Olympus")
    T.eq(ns.lookup.flight, nil)
end)

T.test("a window you open while a lookup is out is left alone", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress("O")
    FriendsFrame.shown = true -- the O binding runs after the addon's key watcher
    LFGParentFrame.shown = true
    wow.whoResults = { { fullName = "Zeus", fullGuildName = "Olympus" } }
    wow.Fire("WHO_LIST_UPDATE")
    wow.Advance(1)
    T.eq(FriendsFrame.shown, true)
    T.eq(LFGParentFrame.shown, true)
end)

T.test("an empty Who list during a lookup is its answer", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    wow.whoResults = {}
    wow.Fire("WHO_LIST_UPDATE")
    T.eq(ns.lookup.flight, nil)
    T.eq(ns.lookup.interval, 5)
end)

T.test("your own /who list is harvested but left open, and the addon keeps waiting", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    wow.whoResults = { { fullName = "Hera", fullGuildName = "Olympus" }, { fullName = "Ares-Forever", fullGuildName = "" } }
    LFGParentFrame.shown = true
    wow.Fire("WHO_LIST_UPDATE")
    wow.Advance(0)
    T.eq(ns.GuildOfKey("hera-forever"), "Olympus")
    T.eq(ns.GuildOfKey("ares-forever"), "")
    T.ok(ns.lookup.flight, "still waiting for the reply about Zeus")
    T.eq(LFGParentFrame.shown, true)
end)

T.test("guild chat hides when your own guild matches", function()
    wow.Load()
    T.eq(wow.Chat("CHAT_MSG_GUILD", { author = "Zeus" }), true, "not in a guild")
    wow.myGuild = "Olympus II"
    T.eq(wow.Chat("CHAT_MSG_GUILD", { author = "Zeus" }), false)
    T.eq(wow.Chat("CHAT_MSG_OFFICER", { author = "Zeus" }), false)
    T.eq(wow.Chat("CHAT_MSG_GUILD", { author = "Me" }), true, "your own guild lines")
end)

T.test("chat types and channels can be left visible", function()
    local ns = wow.Load()
    SeeZeus()
    ns.settings.shown.say = true
    ns.settings.shownChannels.trade = true
    ns.SettingsChanged(true)
    T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Zeus", guid = ZEUS.guid }), true)
    T.eq(wow.Chat("CHAT_MSG_YELL", { author = "Zeus", guid = ZEUS.guid }), false)
    T.eq(wow.Chat("CHAT_MSG_CHANNEL", { author = "Zeus", guid = ZEUS.guid, channel = "Trade - City" }), true)
    T.eq(wow.Chat("CHAT_MSG_CHANNEL", { author = "Zeus", guid = ZEUS.guid, channel = "General - Elwynn Forest" }), false)
end)

T.test("turning the addon off shows everything", function()
    local ns = wow.Load()
    wow.Advance(60)
    SeeZeus()
    Slash("off")
    T.eq(ns.settings.enabled, false)
    T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Zeus", guid = ZEUS.guid }), true)
    Slash("on")
    T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Zeus", guid = ZEUS.guid }), false)
end)

T.test("adding a phrase removes lines already on screen", function()
    local ns = wow.Load()
    wow.units.target = { name = "Ares", guild = "Titans of War", guid = "Player-1-ARES" }
    wow.Fire("PLAYER_TARGET_CHANGED")
    wow.Chat("CHAT_MSG_SAY", { author = "Ares", guid = "Player-1-ARES", text = "for the titans" })
    T.eq(wow.CountLines("for the titans"), 1)
    wow.Advance(60)
    Slash("add titans")
    wow.Advance(0)
    T.eq(wow.CountLines("for the titans"), 0)
    T.eq(ns.settings.phrases, "Olympus, titans")
    Slash("remove Titans")
    T.eq(ns.settings.phrases, "Olympus")
end)

T.test("a change made before the saved settings arrive is merged with them", function()
    local ns = wow.Load()
    Slash("add Pantheon")
    Slash("remove Olympus")
    T.eq(ns.settings.phrases, "Pantheon")
    T.eq(wow.macroWrites, 0, "nothing is written before the macro list has been read")
    wow.macros = { { name = "GuildMute", body = "#GuildMute 1\n#phrases Olympus, Titans\n#options notypo" } }
    wow.Fire("UPDATE_MACROS")
    T.eq(ns.settings.phrases, "Titans, Pantheon", "stored Titans kept, the session's add and removal applied")
    T.eq(ns.settings.typo, false, "stored options kept")
    T.eq(wow.macros[1].body, "#GuildMute 1\n#phrases Titans, Pantheon\n#options notypo")
end)

T.test("settings survive a restart through the GuildMute macro", function()
    local ns = wow.Load()
    Slash("add Pantheon")
    ns.settings.shown.say = true
    ns.settings.typo = false
    ns.SettingsChanged(true)
    T.eq(wow.macroWrites, 0, "nothing is written before the macro list has been read")
    wow.Advance(60)
    local macro = wow.macros[1]
    T.ok(macro, "macro created once the wait for the list ran out")
    T.eq(macro.name, "GuildMute")
    T.eq(macro.body, "#GuildMute 1\n#phrases Olympus, Pantheon\n#visible say\n#options notypo")
    local saved = wow.macros

    -- Restart: SavedVariables come back empty (the Forever bug), the macro arrives late.
    ns = wow.Load({ login = false })
    wow.Fire("PLAYER_LOGIN")
    T.eq(ns.settings.phrases, "Olympus", "defaults until the macro list arrives")
    wow.macros = saved
    wow.Fire("UPDATE_MACROS")
    T.eq(ns.settings.phrases, "Olympus, Pantheon")
    T.eq(ns.settings.shown.say, true)
    T.eq(ns.settings.typo, false)
    T.eq(wow.macroWrites, 0, "reading does not write")
    wow.units.target = { name = "Kronos", guild = "The Pantheon", guid = "Player-1-K" }
    wow.Fire("PLAYER_TARGET_CHANGED")
    T.eq(wow.Chat("CHAT_MSG_YELL", { author = "Kronos", guid = "Player-1-K" }), false)
end)

T.test("after /reload the macro is read at login", function()
    local ns = wow.Load({
        setup = function()
            wow.macros = { { name = "GuildMute", body = "#GuildMute 1\n#phrases Titans" } }
        end,
    })
    T.eq(ns.settings.phrases, "Titans")
end)

T.test("a hand-edited macro is picked up and odd lines are ignored", function()
    local ns = wow.Load()
    wow.Advance(60)
    wow.macros[1] = { name = "GuildMute", body = "#GuildMute 1\n#phrases  Zeus Squad , Olympus\n/say hi\n#bogus x\n#OPTIONS nolookup" }
    wow.Fire("UPDATE_MACROS")
    T.same(ns.Phrases(), { "zeus squad", "olympus" })
    T.eq(ns.settings.lookup, false)
    T.eq(ns.settings.typo, true)
end)

T.test("a change made in combat is written after combat", function()
    local ns = wow.Load()
    wow.Advance(60)
    wow.combat = true
    Slash("add Pantheon")
    T.eq(#wow.macros, 0)
    wow.combat = false
    wow.Fire("PLAYER_REGEN_ENABLED")
    T.eq(#wow.macros, 1)
    T.ok(wow.macros[1].body:find("Pantheon", 1, true))
    T.eq(ns.settings.phrases, "Olympus, Pantheon")
end)

T.test("returning to the defaults deletes the macro", function()
    local ns = wow.Load()
    wow.Advance(60)
    Slash("off")
    T.eq(#wow.macros, 1)
    Slash("on")
    T.eq(#wow.macros, 0)
    T.eq(ns.settings.enabled, true)
end)

T.test("settings longer than one macro spill into a second and come back after a restart", function()
    local ns = wow.Load()
    wow.Advance(60)
    local parts = {}
    for i = 1, 24 do
        parts[i] = "Olympus Legion " .. i
    end
    ns.settings.phrases = table.concat(parts, ", ")
    ns.SettingsChanged(true)
    T.eq(#wow.macros, 2)
    T.eq(wow.macros[1].name, "GuildMute")
    T.eq(wow.macros[2].name, "GuildMute 2")
    for _, macro in ipairs(wow.macros) do
        T.ok(#macro.body <= 255, "each macro fits")
    end
    local saved = wow.macros
    ns = wow.Load({ setup = function() wow.macros = saved end })
    T.eq(ns.settings.phrases, table.concat(parts, ", "))
    Slash("remove Olympus Legion 24")
    for i = 23, 12, -1 do
        Slash("remove Olympus Legion " .. i)
    end
    T.eq(#wow.macros, 1, "the second macro goes once the list fits in one")
end)

T.test("a single entry too long for any macro works for the session and says why", function()
    local ns = wow.Load()
    wow.Advance(60)
    ns.settings.phrases = string.rep("x", 300)
    ns.SettingsChanged(true)
    T.eq(#wow.macros, 0)
    T.ok(wow.Printed("too long"))
end)

T.test("full account macros fall back to a character macro", function()
    wow.Load({
        setup = function()
            for i = 1, 120 do
                wow.macros[i] = { name = "M" .. i, body = "" }
            end
        end,
    })
    Slash("add Pantheon")
    T.eq(#wow.macros, 120)
    T.eq(#wow.charMacros, 1)
    T.eq(wow.charMacros[1].name, "GuildMute")
end)

T.test("secret unit values are skipped without errors", function()
    local ns = wow.Load()
    wow.units.nameplate2 = { name = wow.SECRET, guild = "Olympus", guid = "Player-1-S" }
    wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    wow.units.nameplate3 = { name = "Zeus", guild = wow.SECRET, guid = ZEUS.guid }
    wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
    local known = ns.KnownCounts()
    T.eq(known, 0)
end)

T.test("stored lines holding secret values are left alone by the removal pass", function()
    local ns = wow.Load()
    wow.chat[1]:AddMessage("secret line", 1, 1, 1, 1, 1, 1, "CHAT_MSG_SAY", { n = 14, "x", wow.SECRET })
    SeeZeus()
    wow.Advance(0)
    ns.PurgeNow()
    T.eq(wow.CountLines("secret line"), 1)
end)

T.test("an event this client lacks does not stop the addon from loading", function()
    wow.Load({
        setup = function()
            wow.unknownEvents.PLAYER_FOCUS_CHANGED = true
        end,
    })
    SeeZeus()
    T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Zeus", guid = ZEUS.guid }), false)
end)

T.test("key presses carry lookups at once, even after a /reload in combat", function()
    wow.Load({
        setup = function()
            wow.combat = true
        end,
    })
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.combat = false
    wow.KeyPress()
    T.eq(#wow.whoQueries, 1, "no restricted call, so nothing waits for combat to end")
end)

T.test("Battle.net whispers resolve through the friend's current character", function()
    wow.Load()
    SeeZeus()
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Zeus", realmName = "Forever", wowProjectID = 1, playerGuid = ZEUS.guid } }
    wow.bnet[8] = { gameAccountInfo = { clientProgram = "App" } }
    T.eq(wow.Chat("CHAT_MSG_BN_WHISPER", { author = "|Kq1|k", bnSenderID = 7 }), false)
    T.eq(wow.Chat("CHAT_MSG_BN_WHISPER", { author = "|Kq2|k", bnSenderID = 8 }), true)
    T.eq(#wow.whoQueries, 0)
end)

T.test("the cache forgets players not seen for two weeks", function()
    local ns = wow.Load({
        setup = function()
            GuildMuteDB = { guilds = { ["zeus-forever"] = { "Olympus", wow.clock - 15 * 86400 }, ["ares-forever"] = { "Titans", wow.clock - 86400 } } }
        end,
    })
    T.eq(ns.GuildOfKey("zeus-forever"), nil)
    T.eq(ns.GuildOfKey("ares-forever"), "Titans")
end)

T.test("slash commands answer", function()
    local ns = wow.Load()
    Slash("test Olypus VI")
    T.ok(wow.Printed("matches \"olympus\" (with one typo)"))
    Slash("test Titans")
    T.ok(wow.Printed("does not match"))
    Slash("status")
    T.ok(wow.Printed("Hiding chat from guilds containing: Olympus"))
    Slash("check Zeus")
    T.same(wow.whoQueries, { "x-Zeus" }, "typing the command is itself a key press")
    T.eq(wow.whoOrigins[1], 3, "sent with the shift-click origin")
    WhoReply("Zeus", "Olympus")
    T.ok(wow.Printed("Zeus is in <Olympus>, so their chat is hidden."))
    Slash("forget")
    T.eq(ns.GuildOfKey("zeus-forever"), nil)
    Slash("help")
    T.ok(wow.Printed("/gmute check <name>"))
    Slash("")
    T.eq(wow.openedCategory, 77, "opens the settings page")
end)

T.test("the settings page builds, lists channels and edits settings", function()
    local ns = wow.Load()
    local panel = wow.optionsPanel
    T.ok(panel, "registered with the Settings panel")
    panel:Show()
    wow.Advance(60)
    Slash("add Pantheon")
    panel.OnDefault()
    T.eq(ns.settings.phrases, "Olympus")
    ns.RefreshOptions()
end)

T.test("your shift-click during a lookup keeps its reply, and the addon's stays hidden", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    -- Bob's reply (the shift-click) arrives before Zeus's.
    T.eq(wow.System(wow.WhoLine("Bob", "Titans")), true)
    T.eq(wow.System("1 player total"), true, "your count line stays")
    T.ok(ns.lookup.flight, "still waiting for Zeus")
    T.eq(wow.System(wow.WhoLine("Zeus", "Olympus")), false)
    T.eq(wow.System("1 player total"), false)
    T.eq(ns.lookup.flight, nil)
end)

T.test("holding Shift to shift-click does not send the addon's query first", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress("LSHIFT")
    wow.KeyPress("RCTRL")
    T.eq(#wow.whoQueries, 0, "modifier keys never carry a query")
    wow.KeyPress("W")
    T.eq(#wow.whoQueries, 1)
end)

T.test("a whisper moves a sender already queued from a channel to the front", function()
    local ns = wow.Load()
    for i = 1, 5 do
        wow.Chat("CHAT_MSG_CHANNEL", { author = "Trader" .. i, guid = "Player-1-T" .. i, channel = "Trade - City" })
    end
    wow.Chat("CHAT_MSG_CHANNEL", { author = "Zeus", guid = ZEUS.guid, channel = "Trade - City" })
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    T.eq(ns.lookup.queue[1].key, "zeus-forever")
    T.eq(#ns.lookup.queue, 6)
end)

T.test("a reply that arrives after its query timed out is still hidden", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.Chat("CHAT_MSG_WHISPER", { author = "Hera", guid = "Player-1-HERA" })
    wow.KeyPress()
    wow.Advance(6)
    T.eq(wow.System(wow.WhoLine("Zeus", "Olympus")), false)
    T.eq(wow.System("1 player total"), false)
    wow.KeyPress()
    T.eq(wow.whoQueries[2], "x-Hera")
    T.eq(wow.System(wow.WhoLine("Hera", "Titans")), false)
    T.eq(wow.System("1 player total"), false)
end)

T.test("a system line that only starts with the player's link is not a /who reply", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    WHO_LIST_GUILD_FORMAT = nil -- force the loose parse
    ns.BuildWhoParsers()
    T.eq(wow.System("|Hplayer:Zeus|h[Zeus]|h has invited you to join a group."), true)
    T.eq(ns.GuildOfKey("zeus-forever"), nil)
    T.eq(wow.System("|Hplayer:Zeus|h[Zeus]|h: Level 20 |cffc79c6eWarrior|r <Olympus> - Goldshire"), false)
    T.eq(ns.GuildOfKey("zeus-forever"), "Olympus")
end)

T.test("a late macro list with a second GuildMute macro is merged into one", function()
    local ns = wow.Load()
    wow.Advance(60)
    Slash("add Titans")
    T.eq(#wow.macros, 1)
    -- The server's list arrives very late and still holds the macro saved last session.
    table.insert(wow.macros, 1, { name = "GuildMute", body = "#GuildMute 1\n#phrases Olympus, Pantheon\n#options notypo" })
    wow.Fire("UPDATE_MACROS")
    T.eq(#wow.macros, 1)
    T.eq(ns.settings.phrases, "Olympus, Pantheon, Titans")
    T.eq(ns.settings.typo, false)
    T.eq(wow.macros[1].body, "#GuildMute 1\n#phrases Olympus, Pantheon, Titans\n#options notypo")
end)

T.test("deleting the macro by hand returns to the defaults", function()
    local ns = wow.Load({
        setup = function()
            wow.macros = { { name = "GuildMute", body = "#GuildMute 1\n#phrases Titans" } }
        end,
    })
    T.eq(ns.settings.phrases, "Titans")
    wow.macros = {}
    wow.Fire("UPDATE_MACROS")
    T.eq(ns.settings.phrases, "Olympus")
end)

T.test("a save that fails after combat says why", function()
    local ns = wow.Load()
    wow.Advance(60)
    wow.combat = true
    ns.settings.phrases = string.rep("x", 300)
    ns.SettingsChanged(true)
    T.ok(not wow.Printed("too long"))
    wow.combat = false
    wow.Fire("PLAYER_REGEN_ENABLED")
    T.ok(wow.Printed("too long"))
end)

T.test("/gmute check works while hiding is off", function()
    wow.Load()
    wow.Advance(60)
    Slash("off")
    Slash("check Zeus")
    T.same(wow.whoQueries, { "x-Zeus" })
end)

T.test("Battle.net community senders are never looked up", function()
    wow.Load()
    T.eq(wow.Chat("CHAT_MSG_COMMUNITIES_CHANNEL", { author = "|Kq12|k", guid = "" }), true)
    wow.KeyPress()
    T.eq(#wow.whoQueries, 0)
end)

T.test("your own lines are safe by GUID before the realm name is known", function()
    wow.Load({
        setup = function()
            GetNormalizedRealmName = function() return nil end
        end,
    })
    wow.myGuild = "Olympus"
    T.eq(wow.Chat("CHAT_MSG_SAY", { author = "Me-Forever", guid = "Player-1-ME" }), true)
    T.eq(wow.Chat("CHAT_MSG_GUILD", { author = "Me-Forever", guid = "Player-1-ME" }), true)
    wow.KeyPress()
    T.eq(#wow.whoQueries, 0)
end)

T.test("achievement lines (stored without their event) are removed too", function()
    wow.Load()
    -- Blizzard stores achievement lines with only their chat type, no event or arguments.
    wow.Chat("CHAT_MSG_ACHIEVEMENT", { author = "Zeus-Forever", guid = ZEUS.guid, text = "%s has earned" })
    wow.chat[1].lines = {
        { message = "|Hplayer:Zeus-Forever|h[Zeus]|h has earned the achievement [Level 20]!", r = 1, g = 1, b = 0, extra = { n = 1, ChatTypeInfo.ACHIEVEMENT.id } },
        { message = "|Hplayer:Ares|h[Ares]|h says hi", r = 1, g = 1, b = 1, extra = { n = 1, ChatTypeInfo.SAY.id } },
    }
    SeeZeus()
    wow.Advance(0)
    T.eq(wow.CountLines("has earned"), 0)
    T.eq(wow.CountLines("says hi"), 1)
end)

T.test("typo tolerance counts letters and only matches whole words", function()
    local ns = wow.Load()
    wow.Advance(60)
    Slash("add Titans")
    T.eq(ns.GuildMatches("Christians Knights"), nil)
    T.eq(ns.GuildMatches("Titanz Guard"), "titans")
    T.eq(ns.GuildMatches("Mount Olypus"), "olympus")
    T.eq(ns.GuildMatches("Olypusx"), nil)
    Slash("add Titan")
    T.eq(ns.GuildMatches("Titn"), nil, "five letters get no typo allowance")
end)

T.test("community streams are left out of the channel list", function()
    wow.Load()
    wow.channels = { 1, "General", false, 3, "Community:123:1", false }
    wow.optionsPanel:Show()
    T.ok(wow.Labelled("General"))
    T.ok(not wow.Labelled("Community:123:1"))
end)

T.test("the speech bubble of a hidden say line is made invisible, others are left alone", function()
    wow.Load()
    SeeZeus()
    wow.bubbles = { { text = "join Olympus today" }, { text = "anyone selling ore?" }, { text = "join Olympus today", forbidden = true } }
    wow.Chat("CHAT_MSG_SAY", { author = "Zeus", guid = ZEUS.guid, text = "join Olympus today" })
    wow.Advance(0)
    T.eq(wow.bubbles[1].frame.alpha, 0)
    T.eq(wow.bubbles[2].frame.alpha, 1)
    T.eq(wow.bubbles[3].frame, nil, "protected instance bubbles are never touched")
    wow.bubbles[1].text = "hello from someone else" -- the game reuses the bubble
    wow.Advance(0.2)
    T.eq(wow.bubbles[1].frame.alpha, 1)
    wow.Advance(2)
    T.eq(#wow.timers, 1, "stops checking once nothing is hidden or awaited; only the macro-list wait remains")
end)

T.test("whisper lines copied into a newly opened window are removed too", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus-Forever", guid = ZEUS.guid, text = "join us" })
    wow.Chat("CHAT_MSG_CHANNEL", { author = "Zeus-Forever", guid = ZEUS.guid, text = "WTS ore", channel = "Trade - City" })
    -- Opening a whisper window from the conversation copies only text and ids.
    wow.history[501] = "WHISPER"
    wow.history[502] = "CHANNEL2"
    wow.history[503] = "WHISPER"
    wow.chat[2].lines = {
        { message = "|Hplayer:Zeus-Forever:88:WHISPER|h[Zeus]|h whispers: join us", r = 1, g = 0.5, b = 1, extra = { n = 3, 7, 900, 501 } },
        { message = "|Hplayer:Zeus-Forever:89:CHANNEL|h[Zeus]|h: WTS ore", r = 1, g = 1, b = 1, extra = { n = 3, 8, 901, 502 } },
        { message = "|Hplayer:Ares:90:WHISPER|h[Ares]|h whispers: hi", r = 1, g = 0.5, b = 1, extra = { n = 3, 7, 902, 503 } },
    }
    wow.ns.settings.shownChannels.trade = true
    SeeZeus()
    wow.Advance(0)
    T.eq(wow.CountLines("join us", 2), 0)
    T.eq(wow.CountLines("WTS ore", 2), 1, "Trade is left visible")
    T.eq(wow.CountLines("whispers: hi", 2), 1)
end)

T.test("an unknown whisperer offline for /who stays visible", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Ares", guid = "Player-1-ARES", text = "bye" })
    wow.KeyPress()
    T.eq(wow.System("0 players total"), false)
    T.eq(wow.CountLines("[Ares]: bye"), 1)
end)

T.test("the Who list is handed to the addon only while its query is out", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    T.eq(wow.whoToUi, true)
    T.ok(not LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"), "the Group Finder's Who list stops listening")
    wow.whoResults = { { fullName = "Zeus", fullGuildName = "Olympus" } }
    wow.Fire("WHO_LIST_UPDATE")
    T.eq(wow.whoToUi, false)
    T.ok(LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))
end)

T.test("your own /who while the addon's is out gets the Who list back at once", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    wow.KeyPress()
    C_FriendList.SendWho("x-Bob") -- a shift-click
    T.eq(wow.whoToUi, false)
    T.ok(LFGWhoListFrame:IsEventRegistered("WHO_LIST_UPDATE"))
    T.ok(ns.lookup.flight.foreign)
    wow.whoResults = {}
    wow.Fire("WHO_LIST_UPDATE")
    T.ok(ns.lookup.flight, "an empty list could be yours, so the addon keeps waiting")
    T.eq(wow.System("0 players total"), true, "and so could an empty count line")
end)

T.test("more players on screen teach guilds: soft targets and your target's target", function()
    local ns = wow.Load()
    wow.units.softfriend = { name = "Hera", guild = "Olympus II", guid = "Player-1-HERA" }
    wow.Fire("PLAYER_SOFT_FRIEND_CHANGED")
    T.eq(ns.GuildOfKey("hera-forever"), "Olympus II")
    wow.units.softenemy = { name = "Kronos", guild = "Titans", guid = "Player-1-K" }
    wow.Fire("PLAYER_SOFT_ENEMY_CHANGED")
    T.eq(ns.GuildOfKey("kronos-forever"), "Titans")
    wow.units.targettarget = { name = "Ares", guild = "Titans", guid = "Player-1-ARES" }
    wow.Fire("PLAYER_TARGET_CHANGED")
    T.eq(ns.GuildOfKey("ares-forever"), "Titans")
end)

T.test("the Communities window drops lines from matching players", function()
    wow.Load()
    local chat = CommunitiesFrame.Chat
    wow.clubs[5] = { clubType = Enum.ClubType.Character }
    local function Post(name, guid, text)
        local message = { author = { name = name, guid = guid }, content = text, messageId = { epoch = 1, position = text } }
        wow.clubMessages[message.messageId] = message
        chat:AddMessage(5, 1, message)
    end
    SeeZeus()
    Post("Zeus", ZEUS.guid, "join us")
    Post("Ares", "Player-1-ARES", "hi all")
    T.eq(wow.CountLines("join us", "Communities"), 1, "removed together on the next frame")
    wow.Advance(0)
    T.eq(wow.CountLines("join us", "Communities"), 0)
    T.eq(wow.CountLines("hi all", "Communities"), 1)
    Post("Hera", "Player-1-HERA", "olympus rules")
    T.eq(wow.CountLines("olympus rules", "Communities"), 1, "unknown for now")
    wow.units.target = { name = "Hera", guild = "Olympus", guid = "Player-1-HERA" }
    wow.Fire("PLAYER_TARGET_CHANGED")
    wow.Advance(0)
    T.eq(wow.CountLines("olympus rules", "Communities"), 0, "removed once her guild is known")
end)

T.test("the settings page grows to fit a long channel list", function()
    wow.Load()
    wow.channels = {}
    for i = 1, 20 do
        table.insert(wow.channels, i)
        table.insert(wow.channels, "Custom" .. i)
        table.insert(wow.channels, false)
    end
    wow.optionsPanel:Show()
    local tall = nil
    for _, frame in ipairs(wow.frames) do
        if rawget(frame, "height") then
            tall = math.max(tall or 0, frame.height)
        end
    end
    T.ok(tall and tall > 600, "the scrolling content is taller than the page")
end)

T.test("your shift-click on a player the addon just looked up shows as usual", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Ares", guid = "Player-1-ARES", text = "hi" })
    wow.KeyPress()
    WhoReply("Ares", "Titans")
    C_FriendList.SendWho("x-Ares")
    T.eq(wow.System(wow.WhoLine("Ares", "Titans")), true)
    T.eq(wow.System("1 player total"), true)
end)

T.test("shift-clicking the player the addon is looking up hands the lookup to you", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid, text = "join us" })
    wow.KeyPress()
    C_FriendList.SendWho("x-Zeus")
    T.eq(ns.lookup.flight, nil)
    T.eq(wow.whoToUi, false)
    T.eq(wow.System(wow.WhoLine("Zeus", "Olympus")), true, "your reply shows")
    T.eq(wow.System("1 player total"), true)
    wow.Advance(0)
    T.eq(wow.CountLines("join us"), 0, "and the addon learned from it: the masked whisper is gone")
    T.eq(wow.CountLines("checking"), 0)
end)

T.test("a /who of your own right before holds the addon's lookup back", function()
    wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    C_FriendList.SendWho("x-Bob")
    wow.KeyPress()
    T.same(wow.whoQueries, { "x-Bob" })
    wow.Advance(5)
    wow.KeyPress()
    T.same(wow.whoQueries, { "x-Bob", "x-Zeus" })
end)

T.test("a /reload in the middle of a lookup does not leave /who routed away from chat", function()
    wow.Load({
        setup = function()
            wow.whoToUi = true
        end,
    })
    T.eq(wow.whoToUi, false)
end)

T.test("the settings macro is not rewritten while it is being written", function()
    local ns = wow.Load()
    wow.Advance(60)
    -- Settings applied from storage (SettingsChanged(false)) while the addon is writing would
    -- be a half-written macro read back.
    local applied = 0
    local changed = ns.SettingsChanged
    ns.SettingsChanged = function(save)
        if not save then
            applied = applied + 1
        end
        return changed(save)
    end
    -- The real UPDATE_MACROS can fire inside EditMacro itself.
    local edit = EditMacro
    EditMacro = function(...)
        local result = edit(...)
        wow.Fire("UPDATE_MACROS")
        return result
    end
    Slash("add Titans")
    Slash("add Pantheon")
    T.eq(ns.settings.phrases, "Olympus, Titans, Pantheon")
    T.eq(wow.macros[1].body, "#GuildMute 1\n#phrases Olympus, Titans, Pantheon")
    T.ok(wow.macroWrites <= 3, "no rewrite loop")
    T.eq(applied, 0, "the addon's own writes are never read back mid-write")
end)

T.test("status names the world-click trigger and the real typo minimum", function()
    local ns = wow.Load()
    Slash("status")
    T.ok(wow.Printed("phrases of 6+ letters"))
    ns.lookup.off.key, ns.lookup.off.world = true, true
    Slash("status")
    T.ok(wow.Printed("WoW refused"))
end)

T.test("an unknown whisper is shown as it is, never masked", function()
    local ns = wow.Load()
    wow.Chat("CHAT_MSG_WHISPER", { author = "Ares", guid = "Player-1-ARES", text = "want to group?" })
    T.eq(wow.CountLines("[Ares]: want to group?"), 1)
    T.eq(wow.CountLines("checking"), 0)
    wow.KeyPress()
    WhoReply("Ares", "Titans")
    T.eq(wow.CountLines("[Ares]: want to group?"), 1)
    T.eq(ns.masked, nil, "no masking code left")
end)

-- The events frame is the one with ADDON_LOADED registered.
local function Registered(event)
    for _, frame in ipairs(wow.eventFrames) do
        if frame.events.ADDON_LOADED then
            return frame.events[event] == true
        end
    end
end

T.test("nothing is filtered, watched or listened to while hiding is off", function()
    wow.Load()
    wow.Advance(60)
    T.eq(#wow.filters.CHAT_MSG_SAY, 1)
    T.ok(Registered("NAME_PLATE_UNIT_ADDED"))
    Slash("off")
    T.eq(#wow.filters.CHAT_MSG_SAY, 0)
    T.eq(#wow.filters.CHAT_MSG_SYSTEM, 0)
    T.ok(not Registered("NAME_PLATE_UNIT_ADDED"))
    T.ok(not Registered("GROUP_ROSTER_UPDATE"))
    T.ok(Registered("UPDATE_MACROS"), "settings storage still listens")
    Slash("on")
    T.eq(#wow.filters.CHAT_MSG_SAY, 1)
    T.ok(Registered("NAME_PLATE_UNIT_ADDED"))
end)

T.test("an empty phrase list turns the work off too", function()
    local ns = wow.Load()
    ns.settings.phrases = ""
    ns.SettingsChanged(false)
    T.eq(#wow.filters.CHAT_MSG_CHANNEL, 0)
    T.ok(not Registered("NAME_PLATE_UNIT_ADDED"))
end)

T.test("chat types left visible have no filter at all", function()
    local ns = wow.Load()
    ns.settings.shown.say = true
    ns.SettingsChanged(false)
    T.eq(#wow.filters.CHAT_MSG_SAY, 0)
    T.eq(#wow.filters.CHAT_MSG_YELL, 1)
    ns.settings.shown.say = nil
    ns.SettingsChanged(false)
    T.eq(#wow.filters.CHAT_MSG_SAY, 1, "added back exactly once")
end)

T.test("the key watcher is only shown while a lookup is queued", function()
    local ns = wow.Load()
    local watcher = wow.allKeyFrames[1]
    T.eq(watcher.shown, false, "idle: no key reaches the addon")
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus", guid = ZEUS.guid })
    T.eq(watcher.shown, true)
    wow.KeyPress()
    T.eq(#ns.lookup.queue, 0)
    T.eq(watcher.shown, false)
end)

T.test("a crowd on nameplates never starts a removal pass", function()
    wow.Load()
    local passes = 0
    for _, frame in ipairs(wow.chat) do
        local remove = frame.RemoveMessagesByPredicate
        frame.RemoveMessagesByPredicate = function(...)
            passes = passes + 1
            return remove(...)
        end
    end
    for i = 1, 200 do
        wow.units.nameplate1 = { name = "Crowd" .. i, guild = i % 4 == 0 and "Olympus" or "Titans", guid = "Player-1-C" .. i }
        wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    end
    wow.Advance(0)
    T.eq(passes, 0, "nobody in the crowd had a line on screen")
    wow.Chat("CHAT_MSG_SAY", { author = "Zeus", guid = ZEUS.guid, text = "hello" })
    SeeZeus()
    wow.Advance(0)
    T.eq(passes, 2, "one pass per chat window for the one sender whose line was shown")
    T.eq(wow.CountLines("hello"), 0)
end)

T.test("every remembered player is kept, compactly, with no cap", function()
    local ns = wow.Load()
    for i = 1, 6000 do
        wow.units.nameplate1 = { name = "P" .. i, guild = "Guild " .. (i % 50), guid = "Player-1-P" .. i }
        wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    end
    T.eq((ns.KnownCounts()), 6000)
    T.eq(type(GuildMuteDB.guilds["p1-forever"]), "string", "a guild name, not a table per player")
    T.eq(GuildMuteDB.seenDay["p1-forever"], nil, "no date kept during the session")
    wow.Fire("PLAYER_LOGOUT")
    T.eq(GuildMuteDB.seenDay["p1-forever"], math.floor(wow.clock / 86400), "stamped with today at logout")
end)

T.test("the first release's saved guilds are converted, and old ones expire", function()
    local ns = wow.Load({
        setup = function()
            GuildMuteDB = { guilds = {
                ["zeus-forever"] = { "Olympus", wow.clock - 86400 },
                ["ares-forever"] = { "Titans", wow.clock - 20 * 86400 },
            } }
        end,
    })
    T.eq(ns.GuildOfKey("zeus-forever"), "Olympus")
    T.eq(ns.GuildOfKey("ares-forever"), nil)
    T.eq((ns.KnownCounts()), 1)
end)

T.test("the settings page is built the first time it is opened", function()
    wow.Load()
    local before = #wow.frames
    wow.optionsPanel:Show()
    T.ok(#wow.frames > before + 20, "its controls are made on first show")
    local after = #wow.frames
    wow.optionsPanel:Hide()
    wow.optionsPanel:Show()
    T.ok(#wow.frames <= after + 2, "and not again (channel boxes reused)")
end)

T.test("the minimap button's menu turns hiding off and on and opens the settings", function()
    local ns = wow.Load()
    wow.Advance(60)
    local button = GuildMuteMinimapButton
    T.ok(button and button.shown, "shown by default")
    button.scripts.OnClick(button, "LeftButton")
    local items = wow.menu.items
    T.eq(items[1].kind, "title")
    T.eq(items[2].kind, "checkbox")
    T.eq(items[3].text, "Settings")
    T.eq(items[2].isSelected(), true)
    items[2].setSelected()
    T.eq(ns.settings.enabled, false)
    T.eq(#wow.filters.CHAT_MSG_SAY, 0, "off really is off")
    T.eq(wow.macros[1].body, "#GuildMute 1\n#options off", "and it is saved")
    items[2].setSelected()
    T.eq(ns.settings.enabled, true)
    items[3].onClick()
    T.eq(wow.openedCategory, 77)
end)

T.test("dragging the minimap button moves it and remembers where", function()
    local ns = wow.Load()
    wow.Advance(60)
    local button = GuildMuteMinimapButton
    button.scripts.OnDragStart(button)
    wow.cursor = { 1000, 700 } -- straight above the minimap's centre
    button.scripts.OnUpdate(button)
    button.scripts.OnDragStop(button)
    T.eq(ns.settings.minimapAngle, 90)
    T.eq(button.scripts.OnUpdate, nil, "no code runs once the drag ends")
    T.eq(wow.macros[1].body, "#GuildMute 1\n#minimap 90")
    local saved = wow.macros
    ns = wow.Load({ setup = function() wow.macros = saved end })
    T.eq(ns.settings.minimapAngle, 90)
end)

T.test("the minimap button can be hidden and brought back", function()
    local ns = wow.Load()
    wow.Advance(60)
    Slash("minimap")
    T.eq(GuildMuteMinimapButton.shown, false)
    T.eq(ns.settings.minimap, false)
    T.eq(wow.macros[1].body, "#GuildMute 1\n#options nominimap")
    Slash("minimap")
    T.eq(GuildMuteMinimapButton.shown, true)
end)

T.test("status reports the addon's memory", function()
    wow.Load()
    Slash("status")
    T.ok(wow.Printed("Memory in use: 123 KB."))
end)

T.test("a Battle.net friend's whisper is removed once their character's guild matches", function()
    wow.Load()
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Zeus", realmName = "Forever", wowProjectID = 1, playerGuid = ZEUS.guid } }
    T.eq(wow.Chat("CHAT_MSG_BN_WHISPER", { author = "|Kq1|k", bnSenderID = 7, text = "hey friend" }), true, "unknown for now")
    SeeZeus()
    wow.Advance(0)
    T.eq(wow.CountLines("hey friend"), 0)
end)

T.test("switching hiding back on picks up lines shown while it was off", function()
    wow.Load()
    wow.Advance(60)
    Slash("off")
    wow.Chat("CHAT_MSG_SAY", { author = "Apollo", guid = "Player-1-APOLLO", text = "earlier line" })
    Slash("on")
    wow.Advance(0)
    wow.units.nameplate1 = { name = "Apollo", guild = "Olympus", guid = "Player-1-APOLLO" }
    wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    wow.Advance(0)
    T.eq(wow.CountLines("earlier line"), 0)
end)

T.test("a full pass rebuilds the list of unknown senders, so an overflow does not last", function()
    local ns = wow.Load()
    for i = 1, 1001 do
        wow.Chat("CHAT_MSG_SAY", { author = "Unknown" .. i, guid = "Player-1-U" .. i, text = "x" })
    end
    wow.chat[1].lines, wow.chat[2].lines = {}, {} -- the windows scrolled on
    wow.units.nameplate1 = { name = "Unknown1", guild = "Olympus", guid = "Player-1-U1" }
    wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    wow.Advance(0)
    local passes = 0
    for _, frame in ipairs(wow.chat) do
        local remove = frame.RemoveMessagesByPredicate
        frame.RemoveMessagesByPredicate = function(...)
            passes = passes + 1
            return remove(...)
        end
    end
    for i = 1, 50 do
        wow.units.nameplate1 = { name = "Newcomer" .. i, guild = "Olympus", guid = "Player-1-N" .. i }
        wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    end
    wow.Advance(0)
    T.eq(passes, 0, "after the full pass, newcomers who never chatted start no pass")
    T.ok(ns)
end)

T.test("a known player who joins a matching guild has their lines removed", function()
    wow.Load()
    wow.units.target = { name = "Hermes", guid = "Player-1-HERMES" }
    wow.Fire("PLAYER_GUILD_UPDATE", "target") -- guildless, and known to be
    wow.Chat("CHAT_MSG_SAY", { author = "Hermes", guid = "Player-1-HERMES", text = "looking for a guild" })
    T.eq(wow.CountLines("looking for a guild"), 1)
    wow.units.target = { name = "Hermes", guild = "Olympus IV", guid = "Player-1-HERMES" }
    wow.Fire("PLAYER_TARGET_CHANGED")
    wow.Advance(0)
    T.eq(wow.CountLines("looking for a guild"), 0)
end)

T.test("a closed Communities window is not scanned", function()
    wow.Load()
    local asked = 0
    local getMessageInfo = C_Club.GetMessageInfo
    C_Club.GetMessageInfo = function(...)
        asked = asked + 1
        return getMessageInfo(...)
    end
    CommunitiesFrame.Chat.shown = false
    wow.chat[1]:AddMessage("x", 1, 1, 1)
    CommunitiesFrame.Chat.MessageFrame:AddMessage("[Zeus]: hi", 1, 1, 1, 5, 1, { epoch = 1 }, 1)
    wow.Chat("CHAT_MSG_SAY", { author = "Zeus", guid = ZEUS.guid, text = "hello" })
    SeeZeus()
    wow.Advance(0)
    T.eq(asked, 0)
end)

T.test("the minimap checkbox on the settings page saves without a full settings change", function()
    local ns = wow.Load()
    wow.Advance(60)
    local changes = 0
    local changed = ns.SettingsChanged
    ns.SettingsChanged = function(...)
        changes = changes + 1
        return changed(...)
    end
    wow.optionsPanel:Show()
    local box
    for _, frame in ipairs(wow.frames) do
        if rawget(frame.Text, "text") == "Show the minimap button" then
            box = frame
        end
    end
    box.checked = false
    box.scripts.OnClick(box)
    T.eq(ns.settings.minimap, false)
    T.eq(GuildMuteMinimapButton.shown, false)
    T.eq(changes, 0)
    T.eq(wow.macros[1].body, "#GuildMute 1\n#options nominimap")
    T.eq(rawget(wow.optionsPanel, "OnRefresh"), nil, "no second refresh when the page opens")
end)

T.test("/gmute check with hiding off keeps its reply out of chat", function()
    wow.Load()
    wow.Advance(60)
    Slash("off")
    T.eq(#wow.filters.CHAT_MSG_SYSTEM, 0)
    wow.whoToUi = false
    Slash("check Zeus")
    T.eq(#wow.filters.CHAT_MSG_SYSTEM, 1, "listening for the reply while it is out")
    T.eq(wow.System(wow.WhoLine("Zeus", "Olympus")), false)
    T.eq(wow.System("1 player total"), false)
    T.ok(wow.Printed("Zeus is in <Olympus>"))
    wow.Advance(0)
    T.eq(#wow.filters.CHAT_MSG_SYSTEM, 0, "and not afterwards")
end)

T.test("the minimap button is placed where the stored settings put it, without a flash at login", function()
    wow.Load({ setup = function()
        wow.macros = { { name = "GuildMute", body = "#GuildMute 1\n#minimap 45" } }
    end })
    T.ok(GuildMuteMinimapButton and GuildMuteMinimapButton.shown, "macros already here: placed at login")
    wow.Load({ setup = function()
        wow.macros = { { name = "GuildMute", body = "#GuildMute 1\n#options nominimap" } }
    end })
    T.eq(GuildMuteMinimapButton, nil, "stored as hidden: never made")
    -- A fresh login: the macro list arrives a moment after PLAYER_LOGIN.
    wow.Load()
    T.eq(GuildMuteMinimapButton, nil, "not shown at its default spot before the macros can arrive")
    wow.Advance(2)
    wow.macros = { { name = "GuildMute", body = "#GuildMute 1\n#options nominimap" } }
    wow.Fire("UPDATE_MACROS")
    wow.Advance(60)
    T.eq(GuildMuteMinimapButton, nil, "a stored hide that arrives within the grace: never shown")
    wow.Load()
    wow.Advance(5)
    T.ok(GuildMuteMinimapButton and GuildMuteMinimapButton.shown, "no macros at all: the defaults, a few seconds in")
    wow.macros = { { name = "GuildMute", body = "#GuildMute 1\n#options nominimap" } }
    wow.Fire("UPDATE_MACROS")
    T.eq(GuildMuteMinimapButton.shown, false, "a stored hide that arrives later still wins")
end)

T.test("senders of lines in a popped-out window survive a full pass and are removed later", function()
    wow.Load()
    wow.Advance(60)
    wow.Chat("CHAT_MSG_WHISPER", { author = "Zeus-Forever", guid = ZEUS.guid, text = "join us" })
    -- Popping the conversation out copies the line with text and ids only and removes the original.
    wow.history[601] = "WHISPER"
    wow.chat[1].lines = {}
    wow.chat[2].lines = { { message = "|Hplayer:Zeus-Forever:88:WHISPER|h[Zeus]|h whispers: join us", r = 1, g = 0.5, b = 1, extra = { n = 3, 7, 900, 601 } } }
    Slash("add Pantheon") -- any settings change runs a full pass
    wow.Advance(0)
    SeeZeus()
    wow.Advance(0)
    T.eq(wow.CountLines("join us", 2), 0)
end)

T.test("a late /gmute check reply with hiding off does not leave the system filter behind", function()
    wow.Load()
    wow.Advance(60)
    Slash("off")
    Slash("check Zeus")
    wow.Advance(10) -- no reply in time
    T.eq(wow.System(wow.WhoLine("Zeus", "Olympus")), false, "the late reply is still kept out of chat")
    T.eq(wow.System("1 player total"), false)
    wow.Advance(60)
    T.eq(#wow.filters.CHAT_MSG_SYSTEM, 0)
end)

T.test("a Battle.net whisper is removed even after the friend switches characters", function()
    wow.Load()
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Zeus", realmName = "Forever", wowProjectID = 1, playerGuid = ZEUS.guid } }
    wow.Chat("CHAT_MSG_BN_WHISPER", { author = "|Kq1|k", bnSenderID = 7, text = "hey friend", lineID = 7001 })
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Alt", realmName = "Forever", wowProjectID = 1, playerGuid = "Player-1-ALT" } }
    SeeZeus()
    wow.Advance(0)
    T.eq(wow.CountLines("hey friend"), 0)
end)

T.test("a Battle.net whisper shown while hiding was off is still removed after the friend switches", function()
    wow.Load()
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Zeus", realmName = "Forever", wowProjectID = 1, playerGuid = ZEUS.guid } }
    Slash("off")
    wow.Chat("CHAT_MSG_BN_WHISPER", { author = "|Kq1|k", bnSenderID = 7, text = "while off", lineID = 7101 })
    Slash("on") -- the full pass notes the character behind the line
    wow.Advance(0)
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Alt", realmName = "Forever", wowProjectID = 1, playerGuid = "Player-1-ALT" } }
    SeeZeus()
    wow.Advance(0)
    T.eq(wow.CountLines("while off"), 0)
end)

T.test("Battle.net whispers without a line id are not mixed up between friends", function()
    wow.Load()
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Zeus", realmName = "Forever", wowProjectID = 1, playerGuid = ZEUS.guid } }
    wow.bnet[8] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Hermes", realmName = "Forever", wowProjectID = 1, playerGuid = "Player-1-HERMES" } }
    wow.Chat("CHAT_MSG_BN_WHISPER", { author = "|Kq1|k", bnSenderID = 7, text = "from zeus", lineID = 0 })
    wow.Chat("CHAT_MSG_BN_WHISPER", { author = "|Kq2|k", bnSenderID = 8, text = "from hermes", lineID = 0 })
    SeeZeus()
    wow.Advance(0)
    T.eq(wow.CountLines("from zeus"), 0, "the muted friend's line goes")
    T.eq(wow.CountLines("from hermes"), 1, "the other friend's line stays")
end)

T.test("the Battle.net line notes stay bounded", function()
    wow.Load()
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Zeus", realmName = "Forever", wowProjectID = 1, playerGuid = ZEUS.guid } }
    -- One past the limit of 500: the notes start over, so only the newest line keeps its character.
    for i = 1, 501 do
        wow.Chat("CHAT_MSG_BN_WHISPER", { author = "|Kq1|k", bnSenderID = 7, text = "bn #" .. i .. "#", lineID = 8000 + i })
    end
    wow.bnet[7] = { gameAccountInfo = { clientProgram = "WoW", characterName = "Alt", realmName = "Forever", wowProjectID = 1, playerGuid = "Player-1-ALT" } }
    SeeZeus()
    wow.Advance(0)
    T.eq(wow.CountLines("bn #501#"), 0, "the newest note is kept")
    T.eq(wow.CountLines("bn #1#"), 1, "older notes were dropped; those lines follow the friend's current character")
end)

T.test("the list of players already looked up starts over past its limit", function()
    local ns = wow.Load()
    wow.Advance(60)
    ns.lookup.tried["Old-Forever"] = true
    ns.lookup.triedCount = 1000
    wow.Chat("CHAT_MSG_WHISPER", { author = "Hera-Forever", guid = "Player-1-HERA", text = "hi" })
    wow.KeyPress("W")
    T.eq(#wow.whoQueries, 1)
    T.eq(ns.lookup.triedCount, 1)
    T.eq(ns.lookup.tried["Old-Forever"], nil)
    T.ok(ns.lookup.tried["hera-forever"] or ns.lookup.tried["Hera-Forever"], "the new query is remembered")
end)

T.test("a guild club whose info arrives late is still recognised", function()
    wow.Load()
    wow.myGuild = "Olympus"
    local chat = CommunitiesFrame.Chat
    local function Post(text, position)
        local message = { author = { name = "Hera", guid = "Player-1-HERA" }, content = text, messageId = { epoch = 1, position = position } }
        wow.clubMessages[message.messageId] = message
        chat:AddMessage(9, 1, message)
        wow.Advance(0)
    end
    Post("before the club info", 1)
    wow.clubs[9] = { clubType = Enum.ClubType.Guild }
    Post("after the club info", 2)
    T.eq(wow.CountLines("after the club info", "Communities"), 0)
end)

T.test("secret club data is left alone", function()
    wow.Load()
    wow.clubs[11] = wow.SECRET
    local message = { author = { name = "Hera", guid = "Player-1-HERA" }, content = "x", messageId = { epoch = 2 } }
    CommunitiesFrame.Chat:AddMessage(11, 1, message)
    CommunitiesFrame.Chat:AddMessage(11, 1, wow.SECRET)
    wow.Advance(0)
    T.ok(true, "no error")
end)

T.test("club tables whose contents are secret are left alone", function()
    wow.Load()
    wow.clubs[12] = wow.LockedTable()
    CommunitiesFrame.Chat:AddMessage(12, 1, { author = { name = "Hera", guid = "Player-1-HERA" }, content = "x", messageId = { epoch = 3 } })
    wow.clubs[13] = { clubType = Enum.ClubType.Character }
    CommunitiesFrame.Chat:AddMessage(13, 1, wow.LockedTable())
    CommunitiesFrame.Chat:AddMessage(13, 1, { author = wow.LockedTable(), content = "y", messageId = { epoch = 4 } })
    wow.Advance(0)
    T.ok(true, "no error")
end)

T.test("switching hiding back on looks up the senders still on screen", function()
    local ns = wow.Load()
    wow.Advance(60)
    Slash("off")
    wow.Chat("CHAT_MSG_WHISPER", { author = "Hera", guid = "Player-1-HERA", text = "hi" })
    T.eq(#ns.lookup.queue, 0)
    Slash("on")
    wow.Advance(0)
    T.eq(ns.lookup.queue[1] and ns.lookup.queue[1].key, "hera-forever")
    wow.KeyPress()
    T.eq(wow.whoQueries[#wow.whoQueries], "x-Hera")
end)

T.done()
