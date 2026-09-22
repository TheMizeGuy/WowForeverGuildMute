-- WoW Forever Guild Mute: guild-name matching and chat-line parsing.
-- Plain string functions with no game API calls, so tests/run.sh can load this file under LuaJIT.

local _, ns = ...

local Match = {}
ns.Match = Match

local ipairs, tonumber, type = ipairs, tonumber, type
local strbyte, strchar, strfind, strgsub = string.byte, string.char, string.find, string.gsub
local strlower, strmatch, strsub = string.lower, string.match, string.sub
local tconcat = table.concat

-- A phrase with at least this many letters still matches a guild name with one typo in it.
Match.TYPO_MIN_LENGTH = 6

-- Lowercase for the two-byte UTF-8 letters guild names use in the game's European and Russian
-- regions: Latin-1 (À-Þ), Latin Extended-A (Ā-ž), Greek (Α-Ω) and Cyrillic (Ѐ-Я). string.lower
-- only handles ASCII.
local function LowerCodepoint(cp)
    if (cp >= 0xC0 and cp <= 0xDE and cp ~= 0xD7) or (cp >= 0x391 and cp <= 0x3AB and cp ~= 0x3A2) then
        return cp + 0x20
    elseif cp >= 0x410 and cp <= 0x42F then
        return cp + 0x20
    elseif cp >= 0x400 and cp <= 0x40F then
        return cp + 0x50
    elseif cp == 0x178 then
        return 0xFF
    elseif (cp >= 0x100 and cp <= 0x137) or (cp >= 0x14A and cp <= 0x177) then
        return cp - cp % 2 + 1 -- capitals are even, each followed by its lowercase
    elseif (cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17E) then
        return cp % 2 == 1 and cp + 1 or cp -- capitals are odd here
    end
    return cp
end

local function LowerTwoByte(pair)
    local b1, b2 = strbyte(pair, 1, 2)
    local cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
    local lower = LowerCodepoint(cp)
    if lower ~= cp then
        return strchar(0xC0 + math.floor(lower / 64), 0x80 + lower % 64)
    end
end

local function Lower(text)
    return (strgsub(strlower(text), "[\195-\208][\128-\191]", LowerTwoByte))
end


-- Lowercases ASCII and accented Latin letters and collapses whitespace, so "Olympus  VI" and
-- "olympus vi" compare equal. Letters from other scripts pass through unchanged.
function Match.Fold(text)
    text = strgsub(Lower(text), "%s+", " ")
    return (strgsub(text, "^ ?(.-) ?$", "%1"))
end

-- Splits the phrase box ("Olympus, Some Other Guild") into folded, de-duplicated phrases.
function Match.ParsePhrases(text)
    local phrases, seen = {}, {}
    for part in strgsub(text or "", "\n", ","):gmatch("[^,]+") do
        local phrase = Match.Fold(part)
        if phrase ~= "" and not seen[phrase] then
            seen[phrase] = true
            phrases[#phrases + 1] = phrase
        end
    end
    return phrases
end

-- Letters in a folded phrase: UTF-8 characters other than spaces.
function Match.LetterCount(text)
    local _, count = strgsub(text, "[^\128-\191 ]", "")
    return count
end

-- The text as a list of UTF-8 characters, so a typo in an accented, Greek or Cyrillic letter
-- costs one edit like any other, and a lookalike letter from another script counts as one typo.
local function Characters(text)
    local chars = {}
    for char in text:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
        chars[#chars + 1] = char
    end
    return chars
end

-- Word separators: whitespace and ASCII punctuation. Characters beyond ASCII count as letters.
local function IsSeparatorChar(char)
    return char == nil or (#char == 1 and not strfind(char, "^%w"))
end

local prevRow, curRow = {}, {}

-- True when some run of whole words in text is within maxEdits insertions, deletions or
-- substitutions of pattern, counted in characters. Requiring whole words keeps a dropped letter
-- from matching part of an unrelated word ("Titans" against "Chris*tians*"). Both strings are
-- short guild names.
function Match.ContainsApprox(text, pattern, maxEdits)
    if strfind(text, pattern, 1, true) then
        return true
    end
    local t, p = Characters(text), Characters(pattern)
    local m, n = #p, #t
    if maxEdits < 1 or m <= maxEdits then
        return false
    end
    for start = 1, n do
        if IsSeparatorChar(t[start - 1]) and not IsSeparatorChar(t[start]) then
            local prev, cur = prevRow, curRow
            for i = 0, m do
                prev[i] = i
            end
            local last = start + m + maxEdits - 1
            if last > n then
                last = n
            end
            for j = start, last do
                local tj = t[j]
                cur[0] = j - start + 1
                for i = 1, m do
                    local best = prev[i - 1] + (p[i] == tj and 0 or 1)
                    local extraTextChar = prev[i] + 1
                    local missingPatternChar = cur[i - 1] + 1
                    if extraTextChar < best then
                        best = extraTextChar
                    end
                    if missingPatternChar < best then
                        best = missingPatternChar
                    end
                    cur[i] = best
                end
                if cur[m] <= maxEdits and IsSeparatorChar(t[j + 1]) then
                    return true
                end
                prev, cur = cur, prev
            end
        end
    end
    return false
end

-- Returns the first folded phrase found in guildName and whether it needed the typo allowance,
-- or nil. Exact matches win over typo matches.
function Match.FindPhrase(guildName, phrases, allowTypo)
    if type(guildName) ~= "string" or guildName == "" then
        return nil
    end
    local folded = Match.Fold(guildName)
    for _, phrase in ipairs(phrases) do
        if strfind(folded, phrase, 1, true) then
            return phrase, false
        end
    end
    if allowTypo then
        for _, phrase in ipairs(phrases) do
            if Match.LetterCount(phrase) >= Match.TYPO_MIN_LENGTH and Match.ContainsApprox(folded, phrase, 1) then
                return phrase, true
            end
        end
    end
    return nil
end

-- Lowercased "name-realm" key for a player. Chat, unit and /who names leave the realm off for
-- players from the player's own realm, and realm spellings differ in spaces and hyphens
-- ("Aerie Peak" versus "AeriePeak"), so both are normalised here.
function Match.NameKey(name, homeRealm)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local char, realm = strmatch(name, "^([^%-]+)%-(.+)$")
    if not char then
        char, realm = name, homeRealm
    end
    if type(realm) ~= "string" then
        return nil
    end
    realm = strgsub(realm, "[%s%-]", "")
    char = strgsub(char, "%s", "")
    if char == "" or realm == "" then
        return nil
    end
    return Lower(char .. "-" .. realm)
end

Match.Lower = Lower

-- Channel key shared by chat events and the joined-channel list: "Trade - City" and
-- "General - Elwynn Forest" become "trade" and "general"; custom channels keep their name.
function Match.ChannelKey(channelName)
    if type(channelName) ~= "string" or channelName == "" then
        return nil
    end
    return Match.Fold(strmatch(channelName, "^(.-) %- ") or channelName)
end

local MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"

-- Compiles a printf-style global string (WHO_LIST_GUILD_FORMAT, WHO_NUM_RESULTS) into an anchored
-- Lua pattern. Returns the pattern plus the literal text that precedes each capture, so callers
-- can find a capture by its surroundings ("|Hplayer:" for the name, "<" for the guild) even in a
-- translation that reorders arguments with "%2$s". The "|4singular:plural;" grammar the client
-- resolves before printing becomes a wildcard.
function Match.CompileFormat(fmt)
    if type(fmt) ~= "string" or fmt == "" then
        return nil
    end
    local parts, prefixes, literal = { "^" }, {}, {}
    local i, len = 1, #fmt
    while i <= len do
        local c = strsub(fmt, i, i)
        local conv, stop
        if c == "%" then
            conv, stop = strmatch(fmt, "^%d*%$?([sd])()", i + 1)
        end
        if conv then
            prefixes[#prefixes + 1] = tconcat(literal)
            literal = {}
            parts[#parts + 1] = conv == "d" and "(%-?%d+)" or "(.-)"
            i = stop
        elseif c == "%" and strsub(fmt, i + 1, i + 1) == "%" then
            literal[#literal + 1] = "%"
            parts[#parts + 1] = "%%"
            i = i + 2
        elseif c == "|" and strsub(fmt, i + 1, i + 1) == "4" and strfind(fmt, ";", i, true) then
            parts[#parts + 1] = ".-"
            literal = {}
            i = strfind(fmt, ";", i, true) + 1
        else
            literal[#literal + 1] = c
            parts[#parts + 1] = (strgsub(c, MAGIC, "%%%0"))
            i = i + 1
        end
    end
    parts[#parts + 1] = "$"
    return tconcat(parts), prefixes
end

local function EndsWith(text, suffix)
    return suffix == "" or strsub(text, -#suffix) == suffix
end

-- Builds a parser for one /who result format. Returns nil when the format has no player link.
function Match.WhoLineParser(fmt)
    local pattern, prefixes = Match.CompileFormat(fmt)
    if not pattern or not prefixes then
        return nil
    end
    local nameIndex, guildIndex
    for index, prefix in ipairs(prefixes) do
        if not nameIndex and EndsWith(prefix, "|Hplayer:") then
            nameIndex = index
        elseif not guildIndex and EndsWith(prefix, "<") then
            guildIndex = index
        end
    end
    if not nameIndex then
        return nil
    end
    -- Returns the linked player name and the guild ("" for a line without one), or nil.
    return function(text)
        local captures = { strmatch(text, pattern) }
        local name = captures[nameIndex]
        if not name or name == "" then
            return nil
        end
        name = strmatch(name, "^[^:]+")
        return name, guildIndex and captures[guildIndex] or ""
    end
end

-- Last-resort parse for a /who result line ("[Name]: Level ..."): the name and whatever sits in
-- the first <...>, or "" when there is none. Only used for the reply to the addon's own /who.
function Match.LooseWhoLine(text)
    local name = strmatch(text, "^|Hplayer:([^:|]+)[^|]*|h%[.-%]|h: ")
    if not name then
        return nil
    end
    return name, strmatch(text, "<([^>]*)>") or ""
end

-- Builds a parser for the "N players total" line that ends a /who reply; it returns N or nil.
function Match.CountLineMatcher(fmt)
    local pattern = Match.CompileFormat(fmt)
    if not pattern then
        return nil
    end
    return function(text)
        return tonumber((strmatch(text, pattern)))
    end
end

return Match
