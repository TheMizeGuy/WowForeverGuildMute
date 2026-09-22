# WoW Forever Guild Mute

Hides chat from players whose guild name contains a word or phrase you choose, in the World of
Warcraft: Forever client (beta build 1.60.x, interface 16001).

The default phrase is `Olympus`. Matching ignores letter case (including accented, Greek and
Cyrillic letters) and finds the phrase anywhere in the guild name, so `Olympus`, `olympus` and
`Olympus VI` are all hidden. One typo (a missing, extra or wrong letter) is allowed in phrases of
six or more letters when the misspelling covers whole words, so `Olypus VI` is hidden too while
`Christians` does not match `Titans`; switch the typo allowance off in the settings if it catches
a guild it should not.

Every chat type is hidden by default: say, yell, emotes, whispers (with your replies and their
away messages), Battle.net whispers from a friend playing a matching character, party, raid and
raid warnings, instance, guild, officer, every channel (General, Trade, custom), communities,
achievement announcements and voice transcripts, plus the Communities window. The speech bubble
over a hidden player's head is hidden with their say, yell or party line. Each chat type and each
channel you are in can be left visible instead.

## Settings

The minimap button (drag it around the minimap's edge) opens a small menu: hiding on or off, and
Settings. `/gmute`, the addons button by the minimap, and Esc > Options > AddOns > Guild Mute open
the same settings page. Type the guild words into the box, separated by commas, and press Enter.
The page also tests a guild name against your list, shows what the addon knows, and can hide the
minimap button (`/gmute minimap` brings it back).

### Saving on the Forever beta

Build 1.60.1.69913 writes addon settings to disk but never loads them back, so every addon forgets
its settings at each login. Macros are kept on Blizzard's servers and survive restarts, so any
setting that differs from the defaults is also stored in a General macro named `GuildMute`:

```
#GuildMute 1
#phrases Olympus, Pantheon
#visible say
#minimap 90
#options notypo
```

Every line starts with `#`, which the macro system skips, so clicking the macro does nothing.
You can create or edit it by hand from `/macro` too; the addon picks up the change, and deleting
it returns to the defaults. It uses one General macro slot (a character slot if the General tab
is full). Settings longer than one macro's 255 characters continue in `GuildMute 2`,
`GuildMute 3` and so on. Going back to the defaults deletes them, and so does the Defaults button
in the game's Options window, which resets every addon page. If two GuildMute macros ever exist,
the addon merges them into one. Settings are also written to SavedVariables, so they keep working
once Blizzard fixes the client.

The macro list reaches the game a few seconds after login; the addon checks for it every second
and stops waiting after 60 seconds. A change made before it arrives is kept and merged into the
stored settings when it does: phrases and visible chat types added or removed in the meantime
are applied on top, and everything else stays as stored. A change made in combat is saved when
combat ends.

## Commands

| Command | Effect |
|---|---|
| `/gmute` | Open the settings |
| `/gmute add <words>` | Hide guilds whose name contains these words |
| `/gmute remove <words>` | Take words off the list |
| `/gmute on`, `/gmute off` | Turn hiding on or off |
| `/gmute test <guild name>` | Say whether a guild name would be hidden |
| `/gmute check <name>` | Look up a player's guild with /who and print it |
| `/gmute status` | Show the list, counts and lookup state |
| `/gmute forget` | Forget every learned guild |
| `/gmute minimap` | Show or hide the minimap button |

## How it knows someone's guild

Chat messages carry the sender's name but not their guild, and the game has no call that returns
another player's guild by name. The addon learns guilds from:

- players the client shows you: your target and its target, mouseover, focus, soft targets,
  nameplates, party and raid members and what they target. A sender who is on screen when they
  talk is recognised at once;
- /who results, including the line Blizzard prints when you shift-click a name in chat;
- its own /who for a sender it cannot place yet. WoW only accepts /who during a key press or a
  click, which is why shift-clicking works, so the addon sends the same exact-name query
  shift-click sends on your next key press or click in the game world, at most one every five
  seconds, whispers first. This is the approach the WoWForeverRace addon uses on this client,
  whose testing found key presses accepted for /who. While the query is out, the Who list is
  handed to the addon (`SetWhoToUi`, with the Group Finder's Who list not listening), so the reply
  opens no window and prints nothing; the Who list is handed back as soon as the reply arrives, or
  at once if you send a /who of your own (a shift-click on the very player being looked up takes
  the lookup over, and its reply shows as usual). Modifier keys never carry a query, so your own
  shift-clicks go out alone.

A line from a player the addon cannot place yet, whisper or otherwise, shows as usual. If the
lookup then finds a matching guild, that player's lines are removed from every chat window and
the Communities window, and later ones never show. Every learned guild is remembered for 14 days
(for the session only while the Forever save bug lasts); there is no limit on how many players.

No lookups are sent in combat, during the client's chat lockdown, or while the Who list is open.
When a reply goes missing (the server drops /who that comes too fast), the addon waits twice as
long before the next one, up to 30 seconds. If the client refuses the addon's /who, you see
Blizzard's "Interface action failed because of an AddOn" once, and the addon stops using that
trigger (key presses or world clicks) for the session. With both off, players it has not placed
stay visible until you target, mouse over or shift-click them. Turn
lookups off in the settings if you prefer to learn guilds only from what you see.

## Keeping it light

The addon only works while hiding is on and there is at least one phrase. Otherwise it registers
no chat filters, listens to no unit events and watches no keys. While on:

- chat filters are registered only for the chat types being hidden; Blizzard wraps every filter
  call in a secure call and packs its arguments, so a chat type left visible costs nothing;
- the key watcher that carries lookups is only shown while a lookup is queued, so an idle addon
  is never called on a key press; it is built from Blizzard's InsecureKeyboardInputPropagatorTemplate,
  so it needs no restricted call and works from the first key, even after a /reload in combat;
- a player's guild is kept as a shared guild-name string (no table per player), with a date only
  for players loaded from an earlier session; name keys for chat authors are cached;
- a removal pass over the chat windows runs only for players whose lines were shown while their
  guild was unknown, not for every player a nameplate reveals;
- raid roster updates are handled once per burst; the Communities window is only looked at while
  it is open (opening it re-adds its lines through the addon's hook), and a club's type is looked
  up once; the macro list is only written after combat when a write was waiting;
- the settings page and the minimap button are built only when they are first shown;
- only learned guilds are kept without a limit. The list of players already looked up starts over
  after 1,000 (a player /who never found may then be looked up once more), and the note of which
  character sent a Battle.net whisper starts over after 500 lines (such a line then goes by the
  friend's current character).

`/gmute status` reports the addon's memory use. `luajit tests/bench.lua` times the hot paths under
the fake client with LuaJIT's compiler off, since the client runs plain Lua 5.1. Per chat line
the addon's own work is about 0.4 microseconds on top of Blizzard's wrapping of every filter call
(which a filter that does nothing costs too), and it allocates nothing.

## Limits

- A sender whose guild is not known yet is shown until it is, as described above.
- /who only finds players on your own faction who are online.
- Speech bubbles inside instances are protected from addons and stay. Outside, a bubble showing
  the same words from another player in the same second is hidden too.
- When the client is in its chat security lockdown, it does not pass messages to addon filters
  at all, so lines in that window cannot be hidden.
- With whispers set to open in a new tab, the game opens that tab before any addon sees the
  message, so a hidden whisper can leave an empty tab. Text to speech also reads messages before
  addons see them.
- Removing a phrase does not bring back lines that were already hidden.

## Install

Copy the `GuildMute` folder into the Forever client's AddOns directory:

```
C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\GuildMute
```

A brand-new addon is picked up at the character selection screen, not by `/reload`. Log out to
character select and back in. After editing a `.toc` file, restart the client.

`scripts/deploy.sh [ssh-host] [addons-dir]` streams the folder to a Windows machine over ssh
and checks the file count. `addons-dir` defaults to the path above and `ssh-host` to the
author's machine, so pass both when deploying to your own.

## Checks

`tests/run.sh` checks Lua syntax (`luajit -bl`), that both TOC files agree and list every Lua
file, that every global, `C_` function, `Enum` path and frame method the addon uses exists in the
Forever 1.60.1 (69913) client (`tests/audit_globals.py`, against the client's UI source, API
documentation and global strings; `python3 tests/audit_globals.py --fetch` downloads those into
`.cache/` once), then runs the LuaJIT suites. `tests/test_match.lua` covers matching and /who
parsing. `tests/test_addon.lua` loads the addon under a fake client (`tests/wow.lua`, whose /who
strings are the build's own) and drives chat events, unit sightings, /who replies, key presses,
world clicks, combat, refusals, the Communities window, the minimap button and the macro store. The
script must end with `ALL PASSED`. Only the game itself can confirm the macro timing and the
settings page layout.

## Release

Bump `## Version` in both `.toc` files, then build the zip with the addon folder at its root:

```
zip -r -X dist/GuildMute-<version>.zip GuildMute -x '*.DS_Store' -x '*/._*'
```

The CurseForge logo is `art/icon/avatar.png` (400x400). `art/icon/build.sh` re-renders it in
Blender; `art/icon/NOTES.md` has the concept and the render settings.
