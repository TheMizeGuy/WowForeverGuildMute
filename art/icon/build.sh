#!/usr/bin/env bash
# Rebuild the CurseForge avatar for "WoW Forever Guild Mute" from scratch.
# Runs from any directory; every path is relative to this script's own folder.
#
#   1. ships guildmute_icon.py to mizepc (Windows, RTX 4090)
#   2. renders master.png there: Blender 5.2 / Cycles / OPTIX, 1600x1600, 320 samples,
#      OpenImageDenoise, seed pinned to 0
#   3. copies it back and makes avatar.png (400x400) + sizes.png locally with Pillow
set -euo pipefail
cd "$(dirname "$0")"
python3 remote_render.py --out master.png --size 1600 --samples 320
python3 make_avatar.py master.png
