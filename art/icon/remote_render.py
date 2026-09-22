#!/usr/bin/env python3
"""Ship guildmute_icon.py to mizepc, render it there with Blender/Cycles, pull the PNG back.

Usage:
  python3 remote_render.py --out preview.png --size 520 --samples 24
  python3 remote_render.py --out master.png  --size 1600 --samples 320
Extra pass-through flags: --view Standard|AgX|Filmic  --look None|"Punchy"  --exposure 0.0
                          --palette crimson|azure   (azure is the rejected A/B)
"""
import argparse
import base64
import os
import subprocess
import time

HOST = "mizepc"
RDIR = r"C:\Users\benme\AppData\Local\Temp\guildmute-icon"
RDIR_FWD = "C:/Users/benme/AppData/Local/Temp/guildmute-icon"
BLENDER = r"C:\Program Files\Blender Foundation\Blender 5.2\blender.exe"
HERE = os.path.dirname(os.path.abspath(__file__))


def ps(script: str) -> str:
    enc = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    return subprocess.run(
        ["ssh", HOST, "powershell", "-NoProfile", "-EncodedCommand", enc],
        capture_output=True, text=True,
    ).stdout


def run(args):
    ps(f"New-Item -ItemType Directory -Force -Path '{RDIR}' | Out-Null")
    subprocess.run(["scp", "-q", os.path.join(HERE, "guildmute_icon.py"),
                    f"{HOST}:{RDIR_FWD}/guildmute_icon.py"], check=True)

    remote_out = f"{RDIR}\\{args.out}"
    script = (
        f"& '{BLENDER}' -b --factory-startup -P '{RDIR}\\guildmute_icon.py' -- "
        f"--out '{remote_out}' --size {args.size} --samples {args.samples} "
        f"--view {args.view} --look '{args.look}' --exposure {args.exposure} "
        f"--palette {args.palette} "
        f"2>&1 | Select-String -Pattern 'WROTE|Error|error|Traceback|device|Time:|->|line ' "
        f"| ForEach-Object {{ $_.Line }}"
    )
    t0 = time.time()
    out = ps(script)
    print(out.strip())
    print(f"[render {time.time() - t0:.1f}s]")

    local = os.path.join(HERE, args.out)
    subprocess.run(["scp", "-q", f"{HOST}:{RDIR_FWD}/{args.out}", local], check=True)
    print("local:", local)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="preview.png")
    p.add_argument("--size", default="520")
    p.add_argument("--samples", default="24")
    p.add_argument("--view", default="Standard")
    p.add_argument("--look", default="None")
    p.add_argument("--exposure", default="0.0")
    p.add_argument("--palette", default="crimson")
    run(p.parse_args())
