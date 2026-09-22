#!/usr/bin/env bash
# Copy the GuildMute addon folder into a WoW Forever (Camelot) client on a
# Windows machine reachable over ssh. Files are streamed with tar, so the game
# can keep running; new or changed files are picked up on the next
# logout/login (a brand-new addon needs a trip to the character screen, a
# .toc change needs a full client restart).
#
# Usage: scripts/deploy.sh [ssh-host] [addons-dir]
#   ssh-host    defaults to mizepc (the author's machine)
#   addons-dir  defaults to the Battle.net default install path for the
#               Forever beta: C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns
# Both arguments are trusted operator input; they are interpolated into the
# remote command lines, so quotes and the characters sh and cmd use to chain
# commands are refused.
set -euo pipefail

HOST="${1:-mizepc}"
ADDONS_DIR="${2:-C:\\Program Files (x86)\\World of Warcraft\\_classic_beta_\\Interface\\AddOns}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADDON_NAME="GuildMute"

for arg in "$HOST" "$ADDONS_DIR"; do
  if [[ "$arg" == *[\"\'\$\`\;\&\|]* ]]; then
    echo "unsupported characters in argument: $arg" >&2
    exit 1
  fi
done

if [[ ! -f "$REPO_ROOT/$ADDON_NAME/$ADDON_NAME.toc" ]]; then
  echo "missing $REPO_ROOT/$ADDON_NAME/$ADDON_NAME.toc" >&2
  exit 1
fi

# Count with the same exclusions the tar applies below, or a stray .DS_Store
# would fail a correct deploy.
local_count=$(find "$REPO_ROOT/$ADDON_NAME" -type f ! -name '.DS_Store' ! -name '._*' | wc -l | tr -d ' ')
echo "deploying $ADDON_NAME ($local_count files) to $HOST:$ADDONS_DIR"

# Windows ships bsdtar as tar.exe; -C accepts a quoted Windows path.
# COPYFILE_DISABLE stops macOS tar from adding AppleDouble "._name" entries for files that carry
# extended attributes; they would land on Windows as literal junk files.
COPYFILE_DISABLE=1 tar -cf - -C "$REPO_ROOT" --exclude='.DS_Store' --exclude='._*' "$ADDON_NAME" \
  | ssh "$HOST" "tar -xf - -C \"$ADDONS_DIR\""

remote_count=$(ssh "$HOST" "powershell -NoProfile -NonInteractive -Command \"(Get-ChildItem -Recurse -File '$ADDONS_DIR\\$ADDON_NAME' | Measure-Object).Count\"" | tr -d '\r\n ')
echo "remote file count: $remote_count (local $local_count)"
if [[ "$remote_count" -lt "$local_count" ]]; then
  echo "remote is missing $((local_count - remote_count)) files" >&2
  exit 1
fi
if [[ "$remote_count" -gt "$local_count" ]]; then
  # tar never deletes, so files from an earlier install stay behind and are counted here.
  echo "remote has $((remote_count - local_count)) extra files, probably left from an earlier install" >&2
fi
echo "done"
