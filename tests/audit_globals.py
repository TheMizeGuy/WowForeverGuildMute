#!/usr/bin/env python3
"""Checks that every global, C_ namespace function, Enum value, event and frame method the addon
uses exists in the WoW Forever client.

Only Blizzard files the Forever client loads count: each Blizzard addon's TOC is chosen the way the
client chooses it (_Camelot, then _Mainline, then the plain .toc), its [Family]/[Game] paths are
resolved to Mainline/Camelot, lines limited to other game types are dropped, and XML <Script> and
<Include> files are followed. A name exists when it is a Lua 5.1 or WoW Lua built-in, when the
addon defines it, when a loaded Blizzard file defines it (a global function or assignment, or a
named frame in XML), when the API documentation lists it (functions, events, enum values), when
it is one of the client build's global strings, or, for undocumented C functions, when a loaded
Blizzard file calls it.

Usage: tests/audit_globals.py [--fetch]
  Reads the Forever UI source from .cache/wow-ui-source-forever and the client's global strings
  from .cache/globalstrings-<build>.csv. --fetch downloads whichever is missing (a shallow clone
  of github.com/Gethe/wow-ui-source, branch forever, and wago.tools' GlobalStrings table).
"""

import csv
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(ROOT, "GuildMute")
CACHE = os.path.join(ROOT, ".cache")
UI = os.path.join(CACHE, "wow-ui-source-forever")
ADDONS = os.path.join(UI, "Interface", "AddOns")
DOCS = os.path.join(ADDONS, "Blizzard_APIDocumentationGenerated")
BUILD = "1.60.1.69913"
STRINGS = os.path.join(CACHE, f"globalstrings-{BUILD}.csv")
GAME_TYPES = {"mainline", "camelot"}  # Forever is the camelot game in the mainline family

LUA_BUILTINS = set("""
_G assert collectgarbage error getmetatable ipairs next pairs pcall print rawequal rawget rawset
select setmetatable tonumber tostring type unpack xpcall math string table coroutine
""".split())
# Globals the game engine creates itself rather than any UI file: the root frames and the slash
# command table (Blizzard's own UI code uses all three throughout).
ENGINE = {"UIParent", "WorldFrame", "SlashCmdList"}
# Lua functions the WoW client adds to the global environment.
WOW_LUA = set("""
time date strbyte strchar strfind strgsub strlen strlower strmatch strrep strsub strupper format
tinsert tremove wipe strsplit strtrim hooksecurefunc securecallfunction issecretvalue canaccessvalue
""".split())


def fetch():
    os.makedirs(CACHE, exist_ok=True)
    if not os.path.isdir(UI):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--single-branch", "--branch", "forever",
                        "https://github.com/Gethe/wow-ui-source.git", UI], check=True)
    if not os.path.exists(STRINGS):
        url = f"https://wago.tools/db2/GlobalStrings/csv?build={BUILD}"
        request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(request, timeout=120) as response, open(STRINGS, "wb") as out:
            out.write(response.read())


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def allowed(condition):
    """Whether [AllowLoadGameType ...] / [ExcludeLoadGameType ...] suffixes admit Forever."""
    for kind, types in re.findall(r"\[(AllowLoadGameType|ExcludeLoadGameType)\s+([^\]]+)\]", condition):
        tokens = {t.strip().lower() for t in types.split(",")}
        if kind == "AllowLoadGameType" and not tokens & GAME_TYPES:
            return False
        if kind == "ExcludeLoadGameType" and tokens & GAME_TYPES:
            return False
    return True


def xml_files(path, seen):
    """The Lua and XML files an XML file pulls in, recursively."""
    folder = os.path.dirname(path)
    for _, relative in re.findall(r'<(Script|Include)\s+file="([^"]+)"', read(path)):
        target = os.path.normpath(os.path.join(folder, relative.replace("\\", "/")))
        if os.path.exists(target) and target not in seen:
            seen.add(target)
            if target.endswith(".xml"):
                yield from xml_files(target, seen)
            yield target


def loaded_files():
    files, seen = [], set()
    for name in sorted(os.listdir(ADDONS)):
        folder = os.path.join(ADDONS, name)
        if not os.path.isdir(folder):
            continue
        toc = next((os.path.join(folder, name + s) for s in ("_Camelot.toc", "_Mainline.toc", ".toc")
                    if os.path.exists(os.path.join(folder, name + s))), None)
        if not toc:
            continue
        text = read(toc)
        header = re.search(r"^## AllowLoadGameType:\s*(.+)$", text, re.M)
        if header and not {t.strip().lower() for t in header.group(1).split(",")} & GAME_TYPES:
            continue
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            match = re.match(r"^(.*?)(\s+\[.*)?$", line)
            path, condition = match.group(1), match.group(2) or ""
            if not allowed(condition):
                continue
            path = path.strip().replace("[Family]", "Mainline").replace("[Game]", "Camelot")
            path = path.replace("[TextLocale]", "enUS").replace("\\", "/")
            target = os.path.normpath(os.path.join(folder, path))
            if not os.path.exists(target) or target in seen:
                continue
            seen.add(target)
            if target.endswith(".xml"):
                files.extend(xml_files(target, seen))
            files.append(target)
    return files


def bytecode_globals(path):
    listing = subprocess.run(["luajit", "-bl", path], capture_output=True, check=True).stdout
    listing = listing.decode("utf-8", errors="replace")
    reads = set(re.findall(r'\bGGET\b.*?;\s*"([^"]+)"', listing))
    writes = set(re.findall(r'\bGSET\b.*?;\s*"([^"]+)"', listing))
    return reads, writes


def main():
    if "--fetch" in sys.argv:
        fetch()
    if not os.path.isdir(UI) or not os.path.exists(STRINGS):
        print("  SKIP  no Forever UI source or global strings in .cache (run tests/audit_globals.py --fetch)")
        return 0

    lua, xml = [], []
    for path in loaded_files():
        (xml if path.endswith(".xml") else lua).append(read(path))
    lua_source, xml_source = "\n".join(lua), "\n".join(xml)
    defined = set(re.findall(r"^function\s+([A-Za-z_]\w*)\s*\(", lua_source, re.M))
    defined |= set(re.findall(r"^([A-Za-z_]\w*)\s*=", lua_source, re.M))
    defined |= set(re.findall(r'\bname="([A-Za-z_]\w*)"', xml_source))
    called = set(re.findall(r"(?<![\w.:])([A-Z]\w*)\s*\(", lua_source))

    documented, namespaces, events, enums, docs_text = set(), {"Enum", "Constants"}, set(), set(), []
    for name in os.listdir(DOCS):
        text = read(os.path.join(DOCS, name))
        docs_text.append(text)
        namespace = re.search(r'Namespace = "(\w+)"', text)
        if namespace:
            namespaces.add(namespace.group(1))
        for function in re.findall(r'Name = "(\w+)",\s*Type = "Function"', text):
            documented.add(f"{namespace.group(1)}.{function}" if namespace else function)
        events |= set(re.findall(r'LiteralName = "(\w+)"', text))
        enums |= {f"{e}.{v}" for v, e in re.findall(r'Name = "(\w+)", Type = "(\w+)", EnumValue', text)}
        constants = re.findall(r'Name = "(\w+)",\s*Type = "Constants"', text)
        documented |= {f"Constants.{c}" for c in constants}
    docs_text = "\n".join(docs_text)
    # Enum values Blizzard's loaded code uses exist even when the documentation leaves them out.
    enums |= set(re.findall(r"\bEnum\.(\w+\.\w+)", lua_source))
    with open(STRINGS, newline="", encoding="utf-8") as handle:
        global_strings = {row["BaseTag"] for row in csv.DictReader(handle)}

    reads, writes, code = set(), set(), ""
    toc = read(os.path.join(ADDON, "GuildMute.toc"))
    for path in [os.path.join(ADDON, n) for n in re.findall(r"^(\w+\.lua)$", toc, re.M)]:
        r, w = bytecode_globals(path)
        reads |= r
        writes |= w
        code += read(path)

    problems, counts = [], {"globals": 0, "functions": 0, "enum values": 0, "events": 0, "methods": 0}

    def check(kind, ok, label):
        counts[kind] += 1
        if not ok:
            problems.append(label)

    for name in sorted(reads - writes):
        check("globals", name in LUA_BUILTINS or name in WOW_LUA or name in ENGINE or name in namespaces
              or name in global_strings or name in defined or name in documented or name in called,
              f"global {name}")
    for namespace, function in sorted(set(re.findall(r"\b(C_\w+)\.(\w+)", code))):
        full = f"{namespace}.{function}"
        check("functions", full in documented or f"{full}(" in lua_source, f"function {full}")
    for enum, value in sorted(set(re.findall(r"\bEnum\.(\w+)\.(\w+)", code))):
        check("enum values", f"{enum}.{value}" in enums, f"enum value Enum.{enum}.{value}")
    used_events = set(re.findall(r"\bhandlers\.([A-Z][A-Z0-9_]+)\b", code))
    used_events |= set(re.findall(r'(?:Register|Unregister|IsEvent)\w*\(\s*"([A-Z][A-Z0-9_]+)"', code))
    used_events |= set(re.findall(r'"(CHAT_MSG_[A-Z_]+)"', code))
    for event in sorted(used_events):
        check("events", event in events, f"event {event}")
    for method in sorted(set(re.findall(r":([A-Z]\w*)\(", code))):
        check("methods", f":{method}(" in lua_source or f'Name = "{method}"' in docs_text, f"method :{method}()")

    for problem in problems:
        print(f"  FAIL  not found in the Forever {BUILD} client: {problem}")
    if problems:
        return 1
    summary = ", ".join(f"{count} {kind}" for kind, count in counts.items())
    print(f"  ok    {summary}: all exist in the Forever {BUILD} client")
    return 0


if __name__ == "__main__":
    sys.exit(main())
