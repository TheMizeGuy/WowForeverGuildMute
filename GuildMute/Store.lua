-- WoW Forever Guild Mute: settings storage.
--
-- The Forever beta client (1.60.1.69913) writes SavedVariables to disk but never loads them back,
-- and addon-registered CVars never reach Config.wtf. Macros are kept on Blizzard's servers, so
-- they survive restarts on this build (two addon authors measured it independently). Settings
-- that differ from the defaults are therefore also written to General macros named "GuildMute"
-- (and "GuildMute 2", "GuildMute 3" when they need more than one macro's 255 characters). Every
-- line starts with "#", which the macro system skips, so clicking one does nothing ("#show" is
-- avoided: it sets a macro's icon). SavedVariables stay declared so everything persists normally
-- once Blizzard fixes the client.
--
-- The macro list arrives from the server a little after login. Changes made before it is read are
-- kept and merged into the stored settings when it arrives (a three-way merge against the state
-- the session started from), so neither the stored settings nor the early change is lost. Macros
-- cannot be edited in combat, so writes wait for combat to end.

local _, ns = ...

local Store = {}
ns.Store = Store

local ipairs, pairs, select, tonumber, type = ipairs, pairs, select, tonumber, type
local strgsub, strlower, strmatch = string.gsub, string.lower, string.match
local tconcat, tinsert, tsort = table.concat, table.insert, table.sort

Store.MACRO_NAME = "GuildMute"
Store.MACRO_ICON = 134400 -- INV_Misc_QuestionMark
Store.MACRO_MAX_LENGTH = 255
Store.HEADER = "#GuildMute 1"

-- Seconds after login to stop waiting for the macro list and treat it as read.
Store.MACRO_WAIT = 60

local FLAGS = { "enabled", "typo", "lookup", "minimap", "minimapAngle" }
local SETS = { "shown", "shownChannels" }

function Store.Defaults()
    return {
        enabled = true,
        phrases = "Olympus",
        typo = true,
        lookup = true,
        shown = {}, -- [category key] = true for chat types left visible
        shownChannels = {}, -- [channel key] = true for channels left visible
        minimap = true, -- the minimap button is shown
        minimapAngle = 225, -- its place on the minimap's edge, in degrees
    }
end

function Store.Copy(settings)
    local copy = {}
    for key, value in pairs(settings) do
        if type(value) == "table" then
            local set = {}
            for k, v in pairs(value) do
                set[k] = v
            end
            value = set
        end
        copy[key] = value
    end
    return copy
end

-- The phrase box as separate trimmed entries, in order.
function Store.PhraseParts(text)
    local parts = {}
    for part in strgsub(text or "", "\n", ","):gmatch("[^,]+") do
        part = strmatch(part, "^%s*(.-)%s*$")
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return parts
end

local function SortedKeys(set)
    local keys = {}
    for key, on in pairs(set or {}) do
        if on and type(key) == "string" then
            keys[#keys + 1] = key
        end
    end
    tsort(keys)
    return keys
end

-- Lines of "#key item, item" no longer than limit, splitting a long list over several lines.
local function ListLines(key, items, limit)
    local lines, current = {}, nil
    for _, item in ipairs(items) do
        local candidate = current and (current .. ", " .. item) or ("#" .. key .. " " .. item)
        if current and #candidate > limit then
            lines[#lines + 1] = current
            candidate = "#" .. key .. " " .. item
        end
        current = candidate
    end
    lines[#lines + 1] = current
    return lines
end

local LINE_LIMIT = Store.MACRO_MAX_LENGTH - #Store.HEADER - 1

-- The settings as macro lines (without the header); empty at the defaults.
function Store.Lines(settings)
    local defaults = Store.Defaults()
    local lines = {}
    local function Add(list)
        for _, line in ipairs(list) do
            lines[#lines + 1] = line
        end
    end
    if settings.phrases ~= defaults.phrases then
        local parts = Store.PhraseParts(settings.phrases)
        Add(#parts > 0 and ListLines("phrases", parts, LINE_LIMIT) or { "#phrases" })
    end
    local shown = SortedKeys(settings.shown)
    if #shown > 0 then
        Add(ListLines("visible", shown, LINE_LIMIT))
    end
    local channels = SortedKeys(settings.shownChannels)
    if #channels > 0 then
        Add(ListLines("visiblechannels", channels, LINE_LIMIT))
    end
    if settings.minimapAngle ~= defaults.minimapAngle then
        lines[#lines + 1] = "#minimap " .. math.floor(settings.minimapAngle % 360 + 0.5)
    end
    local options = {}
    if not settings.enabled then
        options[#options + 1] = "off"
    end
    if not settings.minimap then
        options[#options + 1] = "nominimap"
    end
    if not settings.typo then
        options[#options + 1] = "notypo"
    end
    if not settings.lookup then
        options[#options + 1] = "nolookup"
    end
    if #options > 0 then
        lines[#lines + 1] = "#options " .. tconcat(options, ", ")
    end
    return lines
end

-- Macro bodies for these settings, each at most 255 characters and starting with the header;
-- an empty list at the defaults. nil when one entry alone is too long for a macro.
function Store.Bodies(settings)
    local bodies, current = {}, nil
    for _, line in ipairs(Store.Lines(settings)) do
        if #line > LINE_LIMIT then
            return nil
        end
        if current and #current + 1 + #line <= Store.MACRO_MAX_LENGTH then
            current = current .. "\n" .. line
        else
            if current then
                bodies[#bodies + 1] = current
            end
            current = Store.HEADER .. "\n" .. line
        end
    end
    bodies[#bodies + 1] = current
    return bodies
end

local function ParseList(text, set)
    for item in (text or ""):gmatch("[^,]+") do
        item = strlower(strmatch(item, "^%s*(.-)%s*$"))
        if item ~= "" then
            set[item] = true
        end
    end
end

-- Settings from one macro body or a list of them. Lines the parser does not know are ignored and
-- missing lines keep their defaults, so a hand-edited macro cannot break the addon. Repeated
-- lines (a long list, or two GuildMute macros) add up.
function Store.Parse(bodies)
    if type(bodies) == "string" then
        bodies = { bodies }
    end
    local settings = Store.Defaults()
    local phrases, options = nil, {}
    for _, body in ipairs(bodies) do
        for line in body:gmatch("[^\r\n]+") do
            local key, value = strmatch(line, "^%s*#(%a+)%s*(.-)%s*$")
            key = key and strlower(key)
            if key == "phrases" then
                phrases = phrases or {}
                for _, part in ipairs(Store.PhraseParts(value)) do
                    phrases[#phrases + 1] = part
                end
            elseif key == "visible" then
                ParseList(value, settings.shown)
            elseif key == "visiblechannels" then
                ParseList(value, settings.shownChannels)
            elseif key == "options" then
                ParseList(value, options)
            elseif key == "minimap" and tonumber(value) then
                settings.minimapAngle = tonumber(value) % 360
            end
        end
    end
    if phrases then
        local seen, unique = {}, {}
        for _, part in ipairs(phrases) do
            local folded = ns.Match.Fold(part)
            if not seen[folded] then
                seen[folded] = true
                unique[#unique + 1] = part
            end
        end
        settings.phrases = tconcat(unique, ", ")
    end
    settings.enabled = not options.off
    settings.typo = not options.notypo
    settings.lookup = not options.nolookup
    settings.minimap = not options.nominimap
    return settings
end

-- Three-way merge: the stored settings with this session's changes (current against baseline,
-- the state the session started from) applied on top. Phrases and the visible sets merge entry
-- by entry, so an entry added on either side survives and one removed this session goes.
function Store.Merge(stored, baseline, current)
    local merged = Store.Copy(stored)
    for _, key in ipairs(FLAGS) do
        if current[key] ~= baseline[key] then
            merged[key] = current[key]
        end
    end
    if current.phrases ~= baseline.phrases then
        local Fold = ns.Match.Fold
        local before, now = {}, {}
        for _, part in ipairs(Store.PhraseParts(baseline.phrases)) do
            before[Fold(part)] = true
        end
        local currentParts = Store.PhraseParts(current.phrases)
        for _, part in ipairs(currentParts) do
            now[Fold(part)] = true
        end
        local out, seen = {}, {}
        for _, part in ipairs(Store.PhraseParts(stored.phrases)) do
            local folded = Fold(part)
            if not (before[folded] and not now[folded]) and not seen[folded] then
                seen[folded] = true
                out[#out + 1] = part
            end
        end
        for _, part in ipairs(currentParts) do
            local folded = Fold(part)
            if not before[folded] and not seen[folded] then
                seen[folded] = true
                out[#out + 1] = part
            end
        end
        merged.phrases = tconcat(out, ", ")
    end
    for _, key in ipairs(SETS) do
        local base, now, set = baseline[key], current[key], merged[key]
        for item, on in pairs(now) do
            if on and not base[item] then
                set[item] = true
            end
        end
        for item, on in pairs(base) do
            if on and not now[item] then
                set[item] = nil
            end
        end
    end
    return merged
end

-- Macro I/O ---------------------------------------------------------------------------------

local ready = false -- the macro list has arrived (or the wait ran out) and been read
local dirty = false -- settings changed since they were last written
local baseline = Store.Defaults() -- what storage held when last read or written
local written -- the bodies last read or written, joined, to recognise our own writes
local onLoaded -- called with settings to apply when storage supplies them
local flushing = false -- UPDATE_MACROS can fire inside EditMacro; reads wait until the write ends
local readAgain = false
local tidyRewrites = 0 -- rewrites in a row of macros that read back untidy; capped against loops
local TIDY_REWRITE_LIMIT = 2

local function AccountMacroLimit()
    local consts = Constants and Constants.MacroConsts
    return consts and consts.MAX_ACCOUNT_MACROS or 120
end

local function CharacterMacroLimit()
    local consts = Constants and Constants.MacroConsts
    return consts and consts.MAX_CHARACTER_MACROS or 30
end

local function NameFor(position)
    return position == 1 and Store.MACRO_NAME or (Store.MACRO_NAME .. " " .. position)
end

-- Position of a storage macro from its name ("GuildMute" 1, "GuildMute 2" 2), or nil.
local function PositionOf(name)
    if name == Store.MACRO_NAME then
        return 1
    end
    local number = type(name) == "string" and strmatch(name, "^" .. Store.MACRO_NAME .. " (%d+)$")
    return number and tonumber(number)
end

-- Every storage macro, in position order. Character macros are numbered after the General
-- tab's slots.
local function FindMacros()
    local found = {}
    local numAccount, numCharacter = GetNumMacros()
    local base = AccountMacroLimit()
    local function Check(index)
        local name, _, body = GetMacroInfo(index)
        local position = PositionOf(name)
        if position then
            found[#found + 1] = { index = index, name = name, position = position, body = type(body) == "string" and body or "" }
        end
    end
    for index = 1, numAccount or 0 do
        Check(index)
    end
    for index = base + 1, base + (numCharacter or 0) do
        Check(index)
    end
    tsort(found, function(a, b)
        if a.position ~= b.position then
            return a.position < b.position
        end
        return a.index < b.index
    end)
    return found
end

-- A body as the addon compares it: the client may add or drop line-end whitespace.
local function Normalized(body)
    body = strgsub(body or "", "\r", "")
    body = strgsub(body, "[ \t]+\n", "\n")
    return (strgsub(body, "%s+$", ""))
end

local function Joined(list)
    local bodies = {}
    for i, item in ipairs(list) do
        bodies[i] = Normalized(type(item) == "table" and item.body or item)
    end
    return tconcat(bodies, "\0")
end

-- Writes the current settings when that is allowed; otherwise leaves them for later.
-- Returns false plus a reason when the settings cannot be stored at all.
function Store.Flush()
    if not dirty or not ready or InCombatLockdown() then
        return true
    end
    local bodies = Store.Bodies(ns.settings)
    if not bodies then
        dirty = false
        return false, "too long"
    end
    local found = FindMacros()
    local numAccount, numCharacter = GetNumMacros()
    local free = (AccountMacroLimit() - (numAccount or 0)) + (CharacterMacroLimit() - (numCharacter or 0))
    if #bodies - #found > free then
        dirty = false
        return false, "no free macro slot"
    end
    dirty = false
    flushing = true
    local ok = pcall(function()
        -- Surplus and duplicate macros go first, highest index first so the others keep theirs.
        local surplus = {}
        for i = #bodies + 1, #found do
            surplus[#surplus + 1] = found[i].index
        end
        tsort(surplus, function(a, b)
            return a > b
        end)
        for _, index in ipairs(surplus) do
            DeleteMacro(index)
        end
        found = FindMacros()
        -- The client may re-sort macros after each call, so every step looks them up again.
        for position, body in ipairs(bodies) do
            local macro = found[position]
            if macro then
                if Normalized(macro.body) ~= Normalized(body) or macro.name ~= NameFor(position) then
                    EditMacro(macro.index, NameFor(position), nil, body)
                end
            else
                local numAcc = GetNumMacros()
                CreateMacro(NameFor(position), Store.MACRO_ICON, body, (numAcc or 0) >= AccountMacroLimit() or nil)
            end
            found = FindMacros()
        end
    end)
    if not ok then
        flushing = false
        readAgain = false
        return false, "macro error"
    end
    written = Joined(bodies)
    baseline = Store.Copy(ns.settings)
    flushing = false
    if readAgain then
        readAgain = false
        return Store.Read()
    end
    return true
end

-- Marks the settings for saving and writes them as soon as it is allowed.
function Store.Save()
    dirty = true
    return Store.Flush()
end

-- Reads the storage macros. Called when UPDATE_MACROS fires, at login when macros are already
-- present (after /reload), when the list shows up while waiting, after Store.MACRO_WAIT seconds,
-- and when combat ends.
function Store.Read()
    if flushing then
        readAgain = true
        return true
    end
    ready = true
    local found = FindMacros()
    if #found == 0 then
        if written and written ~= "" and not dirty then
            -- The macros were deleted by hand: back to the defaults.
            written = nil
            baseline = Store.Defaults()
            if onLoaded then
                onLoaded(Store.Defaults())
            end
        end
        return Store.Flush()
    end
    local key = Joined(found)
    if key == written then
        return Store.Flush()
    end
    local stored = Store.Parse((function()
        local bodies = {}
        for i, macro in ipairs(found) do
            bodies[i] = macro.body
        end
        return bodies
    end)())
    local merged = Store.Merge(stored, baseline, ns.settings)
    written = key
    baseline = Store.Copy(stored)
    if onLoaded then
        onLoaded(merged)
    end
    -- Rewrite when the session added changes, or the macros are not in their tidy form
    -- (duplicates, a list that fits in fewer macros).
    local bodies = Store.Bodies(merged)
    local tidy = bodies ~= nil and Joined(bodies) == key
    for position, macro in ipairs(found) do
        tidy = tidy and macro.name == NameFor(position)
    end
    if tidy then
        tidyRewrites = 0
    elseif tidyRewrites < TIDY_REWRITE_LIMIT then
        -- Should the client keep changing what the addon writes, stop after a couple of tries
        -- rather than rewrite on every UPDATE_MACROS.
        tidyRewrites = tidyRewrites + 1
        dirty = true
    end
    return Store.Flush()
end

-- After combat: the write (or duplicate clean-up, which marks the settings dirty) that had to
-- wait, if any. Returns like Flush.
function Store.OnCombatEnd()
    if dirty then
        return Store.Flush()
    end
    return true
end

function Store.IsReady()
    return ready
end

function Store.HasMacro()
    return ready and #FindMacros() > 0
end

-- The settings the session starts from (SavedVariables, once Blizzard fixes loading them).
function Store.SetBaseline(settings)
    baseline = Store.Copy(settings)
end

function Store.Init(callback)
    onLoaded = callback
end

-- Test hook: forget storage state between scenarios.
function Store._Reset()
    ready, dirty, written, onLoaded = false, false, nil, nil
    flushing, readAgain, tidyRewrites = false, false, 0
    baseline = Store.Defaults()
end

return Store
