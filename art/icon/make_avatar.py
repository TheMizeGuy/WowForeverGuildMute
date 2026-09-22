#!/usr/bin/env python3
"""Downscale the Blender master render to the 400x400 CurseForge avatar, build the
size-preview strip, and optionally an old-vs-new comparison sheet. Pure Pillow.

  python3 make_avatar.py master.png                     -> avatar.png + sizes.png
  python3 make_avatar.py master.png --prefix check       -> check_avatar.png + ...
  python3 make_avatar.py master.png --compare old.png    -> also compare.png
"""
import argparse
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SIZES = [400, 128, 64, 48, 32]
CMP_SIZES = [400, 64, 48, 32]
BGS = ["#ffffff", "#1b1b1f"]
PAD = 26
GAP = 26
CORNER = 0.16          # CurseForge-ish corner rounding, as a fraction of the tile


def load_master(path):
    im = Image.open(path)
    if im.mode != "RGB":
        im = im.convert("RGB")
    return im


def avatar_from(master, size=400):
    return master.resize((size, size), Image.Resampling.LANCZOS)


def rounded(im, radius_frac=CORNER):
    """Preview-only: show the icon the way CurseForge rounds the square."""
    s = im.size[0]
    ss = 8
    mask = Image.new("L", (s * ss, s * ss), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, s * ss - 1, s * ss - 1],
                        radius=int(s * ss * radius_frac), fill=255)
    return mask.resize((s, s), Image.Resampling.LANCZOS)


def strip(master, out_path):
    tiles = {s: avatar_from(master, s) for s in SIZES}
    row_w = PAD * 2 + sum(SIZES) + GAP * (len(SIZES) - 1)
    row_h = PAD * 2 + SIZES[0]
    canvas = Image.new("RGB", (row_w, row_h * 2), "#ffffff")
    for r, bg in enumerate(BGS):
        band = Image.new("RGB", (row_w, row_h), bg)
        x = PAD
        for s in SIZES:
            t = tiles[s]
            band.paste(t, (x, PAD + (SIZES[0] - s) // 2), rounded(t))
            x += s + GAP
        canvas.paste(band, (0, r * row_h))
    canvas.save(out_path)


def compare(old, new, out_path):
    """Old (top of each pair) vs new, at every size, on white and on #1b1b1f."""
    col_w = PAD * 2 + sum(CMP_SIZES) + GAP * (len(CMP_SIZES) - 1)
    pair_h = PAD + (CMP_SIZES[0] + GAP + CMP_SIZES[0]) + PAD
    canvas = Image.new("RGB", (col_w, pair_h * 2), "#ffffff")
    for r, bg in enumerate(BGS):
        band = Image.new("RGB", (col_w, pair_h), bg)
        for row, master in enumerate((old, new)):
            y = PAD + row * (CMP_SIZES[0] + GAP)
            x = PAD
            for s in CMP_SIZES:
                t = avatar_from(master, s)
                band.paste(t, (x, y + (CMP_SIZES[0] - s) // 2), rounded(t))
                x += s + GAP
        canvas.paste(band, (0, r * pair_h))
    canvas.save(out_path)


def report(av):
    px = av.load()
    w, h = av.size
    lum = []
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b = px[x, y]
            lum.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
    lum.sort()
    n = len(lum)
    print(f"  mode={av.mode} size={av.size}")
    print(f"  luminance p01={lum[n//100]:.0f} p50={lum[n//2]:.0f} "
          f"p99={lum[n*99//100]:.0f} max={lum[-1]:.0f}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("master", nargs="?", default="master.png")
    p.add_argument("--prefix", default="")
    p.add_argument("--compare", default=None,
                   help="a previous master render to sit above this one in compare.png")
    a = p.parse_args()
    m = load_master(os.path.join(HERE, a.master))
    pre = (a.prefix + "_") if a.prefix else ""
    av = avatar_from(m, 400)
    ap = os.path.join(HERE, pre + "avatar.png")
    av.save(ap, optimize=True)
    sp = os.path.join(HERE, pre + "sizes.png")
    strip(m, sp)
    print("avatar:", ap)
    report(av)
    print("sizes: ", sp)
    if a.compare:
        cp = os.path.join(HERE, pre + "compare.png")
        compare(load_master(os.path.join(HERE, a.compare)), m, cp)
        print("compare:", cp)
