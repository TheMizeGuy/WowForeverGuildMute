-- Matching, name keys and /who line parsing (GuildMute/Match.lua), no game API involved.

local T = dofile("tests/t.lua")
local ns = {}
assert(loadfile("GuildMute/Match.lua"))("GuildMute", ns)
local Match = ns.Match

local function Hidden(guild, phrases, typo)
    return Match.FindPhrase(guild, Match.ParsePhrases(phrases), typo) ~= nil
end

T.test("the owner's examples all match Olympus", function()
    for _, guild in ipairs({ "Olympus", "olympus", "OLYMPUS", "Olympus VI", "olympus vi", "Olypus VI", "The Olympus Guild", "Mount Olympus II" }) do
        T.ok(Hidden(guild, "Olympus", true), guild .. " should match")
    end
end)

T.test("a phrase can be typed in any case and with spaces", function()
    T.ok(Hidden("Olympus VI", "olympus vi", true))
    T.ok(Hidden("Olympus   VI", "Olympus VI", false), "runs of spaces collapse")
    T.ok(not Hidden("Olympus V", "Olympus VI", false))
end)

T.test("one typo is allowed only when typo tolerance is on", function()
    T.ok(Hidden("Olypus VI", "Olympus", true))
    T.ok(not Hidden("Olypus VI", "Olympus", false))
    T.ok(Hidden("Olymbus", "Olympus", true), "substitution")
    T.ok(Hidden("Ollympus", "Olympus", true), "insertion")
    T.ok(not Hidden("Olpus", "Olympus", true), "two deletions")
    T.ok(not Hidden("Titans", "Olympus", true))
end)

T.test("phrases under six letters never match with a typo", function()
    T.eq(Match.TYPO_MIN_LENGTH, 6)
    T.ok(not Hidden("Stork Riders", "Storm", true))
    T.ok(Hidden("Stormwind Guard", "Storm", true), "exact matches still count anywhere")
    T.ok(Hidden("Titanz", "Titans", true))
end)

T.test("typo matches must cover whole words", function()
    T.ok(not Hidden("Christians United", "Titans", true))
    T.ok(not Hidden("Olypusx VI", "Olympus", true))
    T.ok(Hidden("[Olypus] Raiders", "Olympus", true), "punctuation separates words")
    T.ok(Hidden("Olympos Legion", "Olympus", true))
    T.ok(Hidden("Olypus-VI", "Olympus", true))
end)

T.test("letters are counted, not bytes, for the typo allowance", function()
    T.eq(Match.LetterCount("olympus"), 7)
    T.eq(Match.LetterCount("ab cd"), 4)
    T.eq(Match.LetterCount("ölymp"), 5)
    T.ok(not Hidden("Ölymb", "Ölymp", true), "five letters, even at six bytes")
end)

T.test("Greek, Cyrillic and Central European capitals fold too", function()
    T.eq(Match.Fold("ΟΛΥΜΠΟΣ"), "ολυμποσ")
    T.eq(Match.Fold("ОЛИМП Ёж"), "олимп ёж")
    T.eq(Match.Fold("ŁÓDŹ ŚWIĘTY Ÿ"), "łódź święty ÿ")
    T.ok(Hidden("Гильдия ОЛИМП", "олимп", false))
end)

T.test("exact matches win over typo matches and report which phrase matched", function()
    local phrases = Match.ParsePhrases("Olympux, Olympus")
    local phrase, typo = Match.FindPhrase("Olympus VI", phrases, true)
    T.eq(phrase, "olympus")
    T.eq(typo, false)
    phrase, typo = Match.FindPhrase("Olypus", Match.ParsePhrases("Olympus"), true)
    T.eq(phrase, "olympus")
    T.eq(typo, true)
end)

T.test("phrase lists split on commas and new lines, dropping blanks and repeats", function()
    T.same(Match.ParsePhrases(" Olympus , ,olympus\nTitans  of  War,"), { "olympus", "titans of war" })
    T.same(Match.ParsePhrases(""), {})
    T.same(Match.ParsePhrases(nil), {})
end)

T.test("accented capitals fold to lowercase", function()
    T.eq(Match.Fold("ÉLITE Ölympus"), "élite ölympus")
    T.ok(Hidden("Die Ölympier", "ölympier", false))
    T.eq(Match.Fold("A×B"), "a×b", "the multiplication sign has no lowercase")
end)

T.test("name keys add the home realm and normalise realm spelling", function()
    T.eq(Match.NameKey("Zeus", "Forever"), "zeus-forever")
    T.eq(Match.NameKey("Zeus-Forever", "Other"), "zeus-forever")
    T.eq(Match.NameKey("Zeus-Aerie Peak", "Forever"), "zeus-aeriepeak")
    T.eq(Match.NameKey("Zeus-Azjol-Nerub", "Forever"), "zeus-azjolnerub")
    T.eq(Match.NameKey("Zeus", nil), nil)
    T.eq(Match.NameKey("", "Forever"), nil)
    T.eq(Match.NameKey(nil, "Forever"), nil)
end)

T.test("channel keys drop the zone suffix", function()
    T.eq(Match.ChannelKey("Trade - City"), "trade")
    T.eq(Match.ChannelKey("General - Elwynn Forest"), "general")
    T.eq(Match.ChannelKey("LookingForGroup"), "lookingforgroup")
    T.eq(Match.ChannelKey("MyCustom"), "mycustom")
    T.eq(Match.ChannelKey(""), nil)
end)

local GUILD_FORMAT = "|Hplayer:%s|h[%s]|h: Level %d %s %s <%s> - %s"
local PLAIN_FORMAT = "|Hplayer:%s|h[%s]|h: Level %d %s %s - %s"

T.test("who lines parse into the linked name and the guild", function()
    local parse = Match.WhoLineParser(GUILD_FORMAT)
    local name, guild = parse(GUILD_FORMAT:format("Zeus-Forever", "Zeus", 20, "Night Elf", "Druid", "Olympus VI", "Darnassus"))
    T.eq(name, "Zeus-Forever")
    T.eq(guild, "Olympus VI")
    T.eq(parse("|Hplayer:Zeus|h[Zeus]|h has come online."), nil)
end)

T.test("guildless who lines parse with an empty guild", function()
    local parse = Match.WhoLineParser(PLAIN_FORMAT)
    local name, guild = parse(PLAIN_FORMAT:format("Hermes", "Hermes", 10, "Gnome", "Mage", "Dun Morogh"))
    T.eq(name, "Hermes")
    T.eq(guild, "")
end)

T.test("reordered translations still find the guild by its angle brackets", function()
    local parse = Match.WhoLineParser("|Hplayer:%1$s|h[%2$s]|h: <%6$s> Stufe %3$d %4$s %5$s - %7$s")
    local name, guild = parse("|Hplayer:Zeus|h[Zeus]|h: <Olympus> Stufe 20 Mensch Krieger - Wald")
    T.eq(name, "Zeus")
    T.eq(guild, "Olympus")
end)

T.test("player links with extra fields keep only the name", function()
    local parse = Match.WhoLineParser(GUILD_FORMAT)
    local name = parse(GUILD_FORMAT:format("Zeus-Forever:123", "Zeus", 20, "Human", "Warrior", "Olympus", "Goldshire"))
    T.eq(name, "Zeus-Forever")
end)

T.test("the loose parse reads a link and the first angle brackets", function()
    T.same({ Match.LooseWhoLine("|Hplayer:Zeus|h[Zeus]|h: Level 20 |cffffffffHuman|r <Olympus> - Goldshire") }, { "Zeus", "Olympus" })
    T.same({ Match.LooseWhoLine("|Hplayer:Zeus|h[Zeus]|h: Level 20 Human - Goldshire") }, { "Zeus", "" })
    T.eq(Match.LooseWhoLine("No link here"), nil)
end)

T.test("count lines match with the plural grammar resolved", function()
    local isCount = Match.CountLineMatcher("%d |4player:players; total")
    T.ok(isCount("1 player total"))
    T.ok(isCount("0 players total"))
    T.ok(not isCount("Zeus has come online."))
end)

T.test("formats without a player link or at all give no parser", function()
    T.eq(Match.WhoLineParser(nil), nil)
    T.eq(Match.WhoLineParser("%s total"), nil)
    T.eq(Match.CountLineMatcher(nil), nil)
end)

T.test("pattern characters in a format are literal", function()
    local pattern = Match.CompileFormat("100%% (%s) [%d]")
    T.ok(("100% (abc) [5]"):match(pattern))
    T.ok(not ("100x (abc) [5]"):match(pattern))
end)

T.done()
