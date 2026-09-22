-- Rough cost of the addon's hot paths under the fake client. LuaJIT runs with its compiler off,
-- like the client's plain Lua 5.1 (compiled, the addon and the baseline filter below are traced
-- differently and the comparison measures the compiler). Absolute numbers are only comparable
-- with each other on one machine. Run from the project root: luajit tests/bench.lua
-- (ADDON_DIR=<folder> benchmarks another copy of the addon).
--
--   load                 Lua memory held after login (fake client frames included)
--   settings page        extra memory once the settings page has been opened
--   per player           memory per player whose guild is remembered (nameplate floods)
--   nameplate            time per player nameplate appearing
--   chat message         time and garbage per chat line through two chat windows, next to the
--                        same delivery through a filter that does nothing (Blizzard's share)
--   chat message, off    the same with hiding switched off
--   system line          time per ordinary system message
--   key press            time per key press with nothing to look up

if jit then
    jit.off()
end

local wow = dofile("tests/wow.lua")

local function Collect()
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count")
end

local function Report(label, value, unit)
    io.write(("  %-26s %10.2f %s\n"):format(label, value, unit))
end

-- Runs the registered filters for an event over both chat windows the way Blizzard's
-- ChatFrameUtil.ProcessMessageEventFilters does on Forever: nothing at all without filters,
-- otherwise the arguments packed once and each filter's results packed again.
local function Deliver(event, ...)
    local filters = wow.filters[event]
    if not filters or #filters == 0 then
        return
    end
    for _, frame in ipairs(wow.chat) do
        local arguments = { n = select("#", ...), ... }
        for _, filter in ipairs(filters) do
            local results = { n = 15, filter(frame, event, unpack(arguments, 1, arguments.n)) }
            if results[1] then
                break
            end
        end
    end
end

io.write("Guild Mute hot paths (fake client, LuaJIT)\n")

wow.Reset()
local before = Collect()
local ns = wow.Load()
wow.Advance(60)
local loaded = Collect()
Report("load", loaded - before, "KB")
wow.optionsPanel:Show()
Report("settings page opened", Collect() - loaded, "KB")

-- Names made in advance, so the benchmark measures the addon rather than its own strings.
local PLAYERS = 5000
local names, guids, units, guildNames = {}, {}, {}, {}
for i = 1, 200 do
    guildNames[i] = (i % 10 == 0) and ("Olympus " .. i) or ("Guild " .. i)
end
for i = 1, PLAYERS do
    names[i], guids[i] = "Player" .. i, "Player-1-" .. i
    units[i] = { name = names[i], guild = guildNames[i % 200 + 1], guid = guids[i] }
end

local startMemory = Collect()
local clock = os.clock()
for i = 1, PLAYERS do
    wow.units.nameplate1 = units[i]
    wow.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
end
local nameplateTime = os.clock() - clock
wow.Advance(0)
Report("per player remembered", (Collect() - startMemory) * 1024 / PLAYERS, "bytes")
Report("nameplate appearing", nameplateTime / PLAYERS * 1e6, "microseconds")

-- Trade chat: lines from 2,000 senders, half of them known.
local LINES = 20000
local authors, senderGuids = {}, {}
for i = 1, 2000 do
    authors[i] = i <= 1000 and names[i] or ("Stranger" .. i)
    senderGuids[i] = i <= 1000 and guids[i] or ("Player-1-S" .. i)
end
local function Trade(first)
    collectgarbage("collect")
    collectgarbage("stop")
    local garbageBefore = collectgarbage("count")
    local start = os.clock()
    for i = 1, LINES do
        local sender = i % 2000 + 1
        Deliver("CHAT_MSG_CHANNEL", "WTS ore", authors[sender], "", "2. Trade - City", "", "", 2, 2, "Trade - City", 0,
            first + i, senderGuids[sender], 0, false)
    end
    local elapsed = os.clock() - start
    local garbage = collectgarbage("count") - garbageBefore
    collectgarbage("restart")
    return elapsed / LINES * 1e6, garbage * 1024 / LINES
end
Trade(100000) -- first pass: tables grow as the senders are met
-- The addon's filter and a filter that does nothing, alternated: the difference is the addon's
-- own work, the rest is Blizzard's packing around every filter call. Medians of five rounds.
local addonFilters = wow.filters.CHAT_MSG_CHANNEL
local noOp = { function() return false end }
local addonTimes, baseTimes, addonGarbage, baseGarbage = {}, {}, {}, {}
for round = 1, 5 do
    wow.filters.CHAT_MSG_CHANNEL = addonFilters
    addonTimes[round], addonGarbage[round] = Trade(200000 + round * 100000)
    wow.filters.CHAT_MSG_CHANNEL = noOp
    baseTimes[round], baseGarbage[round] = Trade(800000 + round * 100000)
end
wow.filters.CHAT_MSG_CHANNEL = addonFilters
local function Median(list)
    local copy = { unpack(list) }
    table.sort(copy)
    return copy[3]
end
Report("chat message, with filter", Median(addonTimes), "microseconds")
Report("chat message, no-op filter", Median(baseTimes), "microseconds")
Report("garbage, with filter", Median(addonGarbage), "bytes")
Report("garbage, no-op filter", Median(baseGarbage), "bytes")

clock = os.clock()
for i = 1, LINES do
    Deliver("CHAT_MSG_SYSTEM", "You have received a new item.", "", "", "", "", "", 0, 0, "", 0, 300000 + i)
end
Report("system line", (os.clock() - clock) / LINES * 1e6, "microseconds")

ns.lookup.queue, ns.lookup.queued = {}, {}
local PRESSES = 100000
clock = os.clock()
for _ = 1, PRESSES do
    wow.KeyPress("W")
end
Report("key press, nothing queued", (os.clock() - clock) / PRESSES * 1e6, "microseconds")

SlashCmdList.GUILDMUTE("off")
local perLine = Trade(400000)
Report("chat message, hiding off", perLine, "microseconds")
