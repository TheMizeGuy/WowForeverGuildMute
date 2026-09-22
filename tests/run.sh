#!/usr/bin/env bash
# One-command check before a deploy or release. Must end with "ALL PASSED".
#   1. Lua syntax of every addon file (the client runs Lua 5.1; luajit -bl rejects 5.2+ syntax)
#   2. both TOCs carry the same directives and file list, and it matches the files on disk
#   3. every global, C_ function, Enum path and frame method the addon uses exists in the Forever
#      client's UI source, API docs or global strings (tests/audit_globals.py; skipped until
#      `python3 tests/audit_globals.py --fetch` has downloaded them into .cache/)
#   4. the LuaJIT suites: matching and parsing, then the whole addon under a fake client
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
say() { printf '%s\n' "$*"; }

say "== Lua syntax"
for file in GuildMute/*.lua; do
  if luajit -bl "$file" >/dev/null; then say "  ok    $file"; else say "  FAIL  $file"; fail=1; fi
done

say "== TOC files"
body() { grep -v '^# ' "$1" | sed '/^$/d'; }
if diff <(body GuildMute/GuildMute.toc) <(body GuildMute/GuildMute_Camelot.toc) >/dev/null; then
  say "  ok    GuildMute.toc and GuildMute_Camelot.toc agree"
else
  say "  FAIL  GuildMute.toc and GuildMute_Camelot.toc differ"; fail=1
fi
listed=$(body GuildMute/GuildMute.toc | grep -v '^##' | sort)
present=$(cd GuildMute && ls *.lua | sort)
if [ "$listed" = "$present" ]; then
  say "  ok    TOC lists exactly the Lua files on disk"
else
  say "  FAIL  TOC file list and GuildMute/*.lua differ"; fail=1
fi

say "== every API the addon uses exists in the Forever client"
python3 tests/audit_globals.py || fail=1

for suite in tests/test_match.lua tests/test_addon.lua; do
  say "== $suite"
  luajit "$suite" || fail=1
done

if [ "$fail" -eq 0 ]; then say "ALL PASSED"; else say "FAILED"; exit 1; fi
