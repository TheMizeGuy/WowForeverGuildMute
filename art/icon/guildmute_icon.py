"""
WoW Forever Guild Mute - CurseForge project avatar.

100% procedural Blender scene: a heraldic heater shield in crimson enamel with a
polished gold rim, a raised ivory speech bubble, and a forged-iron bend (slash)
with a gold chamfer cut heraldically to the shield field.

Headless:
  blender.exe -b --factory-startup -P guildmute_icon.py -- --out out.png --size 1600 --samples 320

Everything (outlines, bevels, materials, lights, backdrop gradient) is generated
from the numbers in CFG/PAL below. No external assets, no textures, no image files.

Optional A/B: --palette azure renders the same crest with a sable-azure field and a
crimson bend. The crimson field is the shipped one; see NOTES.md for the verdict.
"""

import bpy
import bmesh
import math
import sys
import os
from mathutils import Vector

# --------------------------------------------------------------------------- #
# configuration
# --------------------------------------------------------------------------- #

CFG = dict(
    # heater shield outline (x = half width, z = up), built in the XZ plane
    shield_w=1.20,        # half width
    shield_top=1.33,      # top edge z
    shield_straight=0.70, # z where the straight side stops and the arc begins
    shield_bot=-1.42,     # z of the bottom point
    shield_corner=0.13,   # fillet radius on the two top corners
    rim=0.150,            # gold rim width (inward offset to the enamel field)

    # depth layout: camera sits at -Y, so smaller y = closer to the viewer
    gold_y=0.00, gold_t=0.40, gold_bev=0.055,
    field_y=-0.055, field_t=0.30, field_bev=0.030,
    bubble_y=-0.105, bubble_t=0.15, bubble_bev=0.038,
    trim_y=-0.158, trim_t=0.10, trim_bev=0.016,
    bar_y=-0.180, bar_t=0.11, bar_bev=0.042,

    # dark contact line: the shield silhouette grown outward and parked behind it
    halo_out=0.062, halo_y=0.42, halo_t=0.10,

    # speech bubble body
    bub_cx=0.00, bub_cz=0.210, bub_hw=0.755, bub_hh=0.585, bub_r=0.148,
    # tail: base on the bubble's bottom edge, apex down-left in the shield's taper
    tail_x1=-0.400, tail_x2=-0.100, tail_ax=-0.325, tail_az=-0.930,

    # heraldic bend (the slash)
    bar_cx=0.00, bar_cz=0.155, bar_half=0.158, bar_angle=-45.0,
    trim=0.050,        # gold chamfer peeking out around the iron bend
    bend_inset=0.105,  # upper-left end stops this far short of the field edge

    # camera / framing
    focal=110.0, frame_h=3.02, look_z=-0.045,
)

PAL = dict(
    gold_lo=(0.690, 0.472, 0.170),
    gold_hi=(1.000, 0.815, 0.400),
    gold_rough=0.252,
    gold_lobes=3,          # broad specular sweeps around the rim
    gold_phase=0.75,
    gold_sweep=0.24,       # how far a sweep slides along the gold ramp
    gold_rough_sweep=0.062,
    enamel_lo=(0.068, 0.0060, 0.0110),
    enamel_hi=(0.385, 0.0320, 0.0380),
    enamel_radial=0.32,    # darkening of the field toward the rim
    ivory_lo=(0.680, 0.640, 0.565),
    ivory_hi=(0.935, 0.912, 0.862),
    ivory_radial=0.26,
    iron_dark=(0.0055, 0.0060, 0.0085),   # shadowed lower edge of the bend
    iron_body=(0.0225, 0.0235, 0.0300),   # graphite body
    iron_lit=(0.0840, 0.0870, 0.1000),    # lit bevel on the upper edge
    halo=(0.0060, 0.0055, 0.0070),
    bg_diff=(0.016, 0.018, 0.026),
    bg_glow=(0.170, 0.092, 0.048),
    bg_edge=(0.058, 0.046, 0.045),
    env_floor=(0.165, 0.094, 0.042),
    env_mid=(0.026, 0.027, 0.034),
    env_sky=(0.052, 0.062, 0.088),
)

# A/B candidate: sable-azure field, crimson bend. See NOTES.md.
PAL_AZURE = dict(
    enamel_lo=(0.0090, 0.0140, 0.0420),
    enamel_hi=(0.0420, 0.0880, 0.2700),
    iron_dark=(0.0320, 0.0035, 0.0045),
    iron_body=(0.1450, 0.0140, 0.0170),
    iron_lit=(0.4200, 0.0620, 0.0640),
)


# --------------------------------------------------------------------------- #
# 2D helpers
# --------------------------------------------------------------------------- #

def signed_area(pts):
    a = 0.0
    n = len(pts)
    for i in range(n):
        x0, z0 = pts[i]
        x1, z1 = pts[(i + 1) % n]
        a += x0 * z1 - x1 * z0
    return 0.5 * a


def ccw(pts):
    return pts if signed_area(pts) > 0 else pts[::-1]


def dedupe(pts, eps=1e-6):
    out = []
    for p in pts:
        if not out or (abs(p[0] - out[-1][0]) > eps or abs(p[1] - out[-1][1]) > eps):
            out.append(p)
    if len(out) > 1 and abs(out[0][0] - out[-1][0]) < eps and abs(out[0][1] - out[-1][1]) < eps:
        out.pop()
    return out


def arc(cx, cz, r, a0, a1, n):
    """Sampled circular arc, angles in radians, inclusive of both ends."""
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n),
             cz + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]


def clip_half(poly, a, e):
    """Keep the part of `poly` left of the directed line through `a` along `e`."""
    ex, ez = e

    def side(p):
        return ex * (p[1] - a[1]) - ez * (p[0] - a[0])

    def isect(p, q):
        fp, fq = side(p), side(q)
        den = fq - fp
        if abs(den) < 1e-14:
            return q
        t = fp / (fp - fq)
        return (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)

    out = []
    n = len(poly)
    for j in range(n):
        cur, prv = poly[j], poly[j - 1]
        ci, pi = side(cur) >= 0.0, side(prv) >= 0.0
        if ci:
            if not pi:
                out.append(isect(prv, cur))
            out.append(cur)
        elif pi:
            out.append(isect(prv, cur))
    return dedupe(out)


def clip_to_convex(subject, clipper):
    """Clip `subject` against the convex polygon `clipper`."""
    clipper = ccw(clipper)
    out = list(subject)
    n = len(clipper)
    for i in range(n):
        if len(out) < 3:
            return []
        a, b = clipper[i], clipper[(i + 1) % n]
        out = clip_half(out, a, (b[0] - a[0], b[1] - a[1]))
    return out


def offset_polygon(pts, d):
    """Offset a CONVEX polygon: intersection of its shifted half-planes.

    Positive `d` moves the edges inward, negative outward. Done this way rather
    than per-vertex mitering because the shield's bottom point is sharp enough
    that naive mitering folds the outline back on itself.
    """
    pts = ccw(pts)
    xs = [p[0] for p in pts]
    zs = [p[1] for p in pts]
    pad = 2.0 + max(0.0, -d) * 4.0
    out = [(min(xs) - pad, min(zs) - pad), (max(xs) + pad, min(zs) - pad),
           (max(xs) + pad, max(zs) + pad), (min(xs) - pad, max(zs) + pad)]
    n = len(pts)
    for i in range(n):
        a, b = pts[i], pts[(i + 1) % n]
        ex, ez = b[0] - a[0], b[1] - a[1]
        L = math.hypot(ex, ez)
        if L < 1e-9:
            continue
        nx, nz = -ez / L, ex / L          # inward normal for CCW winding
        out = clip_half(out, (a[0] + nx * d, a[1] + nz * d), (ex, ez))
        if len(out) < 3:
            return []
    return simplify(out)


def dist_inside(poly, p):
    """Distance from `p` to the nearest edge of the convex CCW polygon `poly`.

    Positive inside, negative outside.
    """
    d = 1e9
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        ex, ez = b[0] - a[0], b[1] - a[1]
        L = math.hypot(ex, ez)
        if L < 1e-12:
            continue
        d = min(d, (ex * (p[1] - a[1]) - ez * (p[0] - a[0])) / L)
    return d


def simplify(pts, tol=8e-6):
    """Drop vertices that sit within `tol` of the chord through their neighbours."""
    n = len(pts)
    if n < 4:
        return pts
    keep = []
    for i in range(n):
        p = pts[(i - 1) % n]
        v = pts[i]
        q = pts[(i + 1) % n]
        ex, ez = q[0] - p[0], q[1] - p[1]
        L = math.hypot(ex, ez)
        if L < 1e-9:
            continue
        dist = abs(ex * (v[1] - p[1]) - ez * (v[0] - p[0])) / L
        if dist >= tol:
            keep.append(v)
    return keep if len(keep) >= 3 else pts


# --------------------------------------------------------------------------- #
# shapes
# --------------------------------------------------------------------------- #

def shield_outline(c=CFG, seg=110):
    """Classic heater shield: straight top + upper sides, circular arcs to a point."""
    w, top, zs, bot, cr = (c['shield_w'], c['shield_top'],
                           c['shield_straight'], c['shield_bot'], c['shield_corner'])
    d = zs - bot
    R = (w * w + d * d) / (2.0 * w)          # arc tangent to the vertical side
    cx = w - R
    a_end = math.atan2(bot - zs, 0.0 - cx)   # angle of the bottom point

    pts = []
    # top-left corner fillet
    pts += arc(-w + cr, top - cr, cr, math.radians(180), math.radians(90), 8)
    # top edge -> top-right corner fillet
    pts += arc(w - cr, top - cr, cr, math.radians(90), math.radians(0), 8)
    # right side down
    pts.append((w, zs))
    # right arc to the bottom point
    pts += arc(cx, zs, R, 0.0, a_end, seg)
    # mirrored left arc back up
    left = [(-x, z) for (x, z) in arc(cx, zs, R, 0.0, a_end, seg)]
    pts += left[::-1][1:]
    pts.append((-w, zs))
    return ccw(dedupe(pts))


def bubble_outline(c=CFG, seg=12):
    """Rounded rectangle with a long directional tail spike cut into its bottom edge."""
    cx, cz = c['bub_cx'], c['bub_cz']
    hw, hh, r = c['bub_hw'], c['bub_hh'], c['bub_r']
    x0, x1 = cx - hw, cx + hw
    z0, z1 = cz - hh, cz + hh

    pts = []
    # bottom edge, left -> right, with the tail spike inserted
    pts.append((x0 + r, z0))
    pts.append((c['tail_x1'], z0))
    pts.append((c['tail_ax'], c['tail_az']))
    pts.append((c['tail_x2'], z0))
    pts.append((x1 - r, z0))
    pts += arc(x1 - r, z0 + r, r, math.radians(-90), math.radians(0), seg)
    pts += arc(x1 - r, z1 - r, r, math.radians(0), math.radians(90), seg)
    pts += arc(x0 + r, z1 - r, r, math.radians(90), math.radians(180), seg)
    pts += arc(x0 + r, z0 + r, r, math.radians(180), math.radians(270), seg)
    return ccw(dedupe(pts))


def bend_shapes(field, c=CFG):
    """The iron bend and the gold chamfer behind it, as two polygons.

    The lower-right end is cut by the field itself, so it follows the shield's arc.
    The upper-left end is cut square, short of the corner, so the bend never fills
    the top-left of the field with a black wedge at small sizes. The chamfer wraps
    the long edges and the lower-right end but stops flush at that square cut, so
    the cut reads as a forged end rather than a gilded tip.
    """
    a = math.radians(c['bar_angle'])
    ux, uz = math.cos(a), math.sin(a)          # along the bar, toward lower right
    nx, nz = -math.sin(a), math.cos(a)         # across the bar, toward upper right
    L, H = 8.0, c['bar_half']
    cx, cz = c['bar_cx'], c['bar_cz']
    rect = []
    for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        rect.append((cx + ux * L * su + nx * H * sv,
                     cz + uz * L * su + nz * H * sv))
    rect = ccw(rect)

    full = clip_to_convex(rect, field)
    if len(full) < 3:
        return full, []

    # Square off the upper-left end. Binary-search the cut position along the bar
    # for the furthest-out square cut whose two corners still leave `bend_inset`
    # of enamel between the iron and the rim.
    poly = ccw(field)
    n0 = nx * c['bar_cx'] + nz * c['bar_cz']
    h = c['bar_half']

    def clearance(s):
        return min(dist_inside(poly, (ux * s + nx * (n0 + k * h),
                                      uz * s + nz * (n0 + k * h)))
                   for k in (1.0, -1.0))

    lo = min(ux * p[0] + uz * p[1] for p in full)
    hi = ux * c['bar_cx'] + uz * c['bar_cz']
    if clearance(hi) >= c['bend_inset']:
        for _ in range(48):
            mid = 0.5 * (lo + hi)
            if clearance(mid) >= c['bend_inset']:
                hi = mid
            else:
                lo = mid
    s = hi
    cut_at, cut_dir = (ux * s, uz * s), (-nx, -nz)
    bend = clip_half(full, cut_at, cut_dir)
    chamfer = clip_half(clip_to_convex(offset_polygon(bend, -c['trim']), field),
                        cut_at, cut_dir)
    return bend, chamfer


# --------------------------------------------------------------------------- #
# mesh building
# --------------------------------------------------------------------------- #

def make_solid(name, pts, y_front, thickness, bevel_w, segments=8, smooth_deg=38.0):
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    bm = bmesh.new()
    vs = [bm.verts.new((p[0], y_front, p[1])) for p in pts]
    bm.verts.ensure_lookup_table()
    n = len(vs)
    es = [bm.edges.new((vs[i], vs[(i + 1) % n])) for i in range(n)]
    bmesh.ops.triangle_fill(bm, use_beauty=True, use_dissolve=True, edges=es)
    bm.faces.ensure_lookup_table()
    faces = list(bm.faces)
    bmesh.ops.recalc_face_normals(bm, faces=faces)
    if faces[0].normal.y > 0:
        bmesh.ops.reverse_faces(bm, faces=faces)

    ret = bmesh.ops.extrude_face_region(bm, geom=faces)
    moved = [e for e in ret['geom'] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, verts=moved, vec=(0.0, thickness, 0.0))
    bm.faces.ensure_lookup_table()
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(mesh)
    bm.free()

    if bevel_w > 0.0:
        bev = obj.modifiers.new("bevel", 'BEVEL')
        bev.width = bevel_w
        bev.segments = segments
        bev.limit_method = 'ANGLE'
        bev.angle_limit = math.radians(30.0)
        bev.miter_outer = 'MITER_ARC'
        bev.use_clamp_overlap = True

    bpy.context.view_layer.objects.active = obj
    try:
        bpy.ops.object.shade_auto_smooth(angle=math.radians(smooth_deg))
    except Exception:
        try:
            bpy.ops.object.shade_smooth()
        except Exception:
            pass
    return obj


# --------------------------------------------------------------------------- #
# material helpers
# --------------------------------------------------------------------------- #

def principled(mat):
    return next(n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')


def set_in(node, names, value):
    if isinstance(names, str):
        names = [names]
    for nm in names:
        if nm in node.inputs:
            node.inputs[nm].default_value = value
            return True
    return False


def new_mat(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    return mat


def math_node(nt, op, a=None, b=None, c=None):
    n = nt.nodes.new('ShaderNodeMath')
    n.operation = op
    for i, v in enumerate((a, b, c)):
        if v is not None and i < len(n.inputs):
            n.inputs[i].default_value = v
    return n


def coords(mat):
    """(Generated Z, Object separate-XYZ) - the two drivers every crest material uses."""
    nt = mat.node_tree
    tex = nt.nodes.new('ShaderNodeTexCoord')
    gen = nt.nodes.new('ShaderNodeSeparateXYZ')
    obj = nt.nodes.new('ShaderNodeSeparateXYZ')
    nt.links.new(tex.outputs['Generated'], gen.inputs[0])
    nt.links.new(tex.outputs['Object'], obj.inputs[0])
    return gen.outputs['Z'], obj


def radial(nt, osep, cx, cz, rx, rz, r0, r1):
    """0 at the centre, 1 past `r1`, on an ellipse in object space."""
    dx = math_node(nt, 'MULTIPLY', None, 1.0 / rx)
    ox = math_node(nt, 'SUBTRACT', None, cx)
    nt.links.new(osep.outputs['X'], ox.inputs[0])
    nt.links.new(ox.outputs[0], dx.inputs[0])
    dz = math_node(nt, 'MULTIPLY', None, 1.0 / rz)
    oz = math_node(nt, 'SUBTRACT', None, cz)
    nt.links.new(osep.outputs['Z'], oz.inputs[0])
    nt.links.new(oz.outputs[0], dz.inputs[0])
    sx = math_node(nt, 'MULTIPLY')
    nt.links.new(dx.outputs[0], sx.inputs[0])
    nt.links.new(dx.outputs[0], sx.inputs[1])
    sz = math_node(nt, 'MULTIPLY')
    nt.links.new(dz.outputs[0], sz.inputs[0])
    nt.links.new(dz.outputs[0], sz.inputs[1])
    ss = math_node(nt, 'ADD')
    nt.links.new(sx.outputs[0], ss.inputs[0])
    nt.links.new(sz.outputs[0], ss.inputs[1])
    rr = math_node(nt, 'SQRT')
    nt.links.new(ss.outputs[0], rr.inputs[0])
    rng = nt.nodes.new('ShaderNodeMapRange')
    rng.clamp = True
    rng.interpolation_type = 'SMOOTHSTEP'
    nt.links.new(rr.outputs[0], rng.inputs[0])
    rng.inputs[1].default_value = r0
    rng.inputs[2].default_value = r1
    rng.inputs[3].default_value = 0.0
    rng.inputs[4].default_value = 1.0
    return rng.outputs[0]


def two_stop_ramp(nt, fac, lo, hi):
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.interpolation = 'EASE'
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = (lo[0], lo[1], lo[2], 1.0)
    ramp.color_ramp.elements[1].position = 1.0
    ramp.color_ramp.elements[1].color = (hi[0], hi[1], hi[2], 1.0)
    nt.links.new(fac, ramp.inputs[0])
    return ramp


def mat_gold(pal, sweep=True):
    """Polished gold. Its brightness and roughness sweep in broad lobes around the
    rim, so the ring carries three separate specular runs instead of one long one."""
    mat = new_mat("gold_sweep" if sweep else "gold_flat")
    b = principled(mat)
    nt = mat.node_tree
    set_in(b, 'Metallic', 1.0)
    set_in(b, ['IOR'], 1.6)
    genz, osep = coords(mat)
    fac = genz
    if sweep:
        ang = math_node(nt, 'ARCTAN2')
        nt.links.new(osep.outputs['Z'], ang.inputs[0])
        nt.links.new(osep.outputs['X'], ang.inputs[1])
        lob = math_node(nt, 'MULTIPLY_ADD', None, float(pal['gold_lobes']), pal['gold_phase'])
        nt.links.new(ang.outputs[0], lob.inputs[0])
        wav = math_node(nt, 'SINE')
        nt.links.new(lob.outputs[0], wav.inputs[0])
        mix = math_node(nt, 'MULTIPLY_ADD', None, pal['gold_sweep'], 0.0)
        nt.links.new(wav.outputs[0], mix.inputs[0])
        nt.links.new(genz, mix.inputs[2])
        fac = mix.outputs[0]
        rgh = math_node(nt, 'MULTIPLY_ADD', None, -pal['gold_rough_sweep'], pal['gold_rough'])
        nt.links.new(wav.outputs[0], rgh.inputs[0])
        nt.links.new(rgh.outputs[0], b.inputs['Roughness'])
    else:
        set_in(b, 'Roughness', pal['gold_rough'])
    ramp = two_stop_ramp(nt, fac, pal['gold_lo'], pal['gold_hi'])
    nt.links.new(ramp.outputs['Color'], b.inputs['Base Color'])
    return mat


def mat_enamel(pal):
    """Crimson enamel: vertical ramp, plus a soft radial fall-off toward the rim."""
    mat = new_mat("enamel")
    b = principled(mat)
    nt = mat.node_tree
    set_in(b, 'Metallic', 0.0)
    set_in(b, 'Roughness', 0.30)
    set_in(b, ['Coat Weight', 'Coat'], 1.0)
    set_in(b, ['Coat Roughness'], 0.045)
    set_in(b, ['Specular IOR Level', 'Specular'], 0.5)
    genz, osep = coords(mat)
    rad = radial(nt, osep, 0.0, 0.10, 1.05, 1.25, 0.52, 1.06)
    fac = math_node(nt, 'MULTIPLY_ADD', None, -pal['enamel_radial'], 0.0)
    nt.links.new(rad, fac.inputs[0])
    nt.links.new(genz, fac.inputs[2])
    ramp = two_stop_ramp(nt, fac.outputs[0], pal['enamel_lo'], pal['enamel_hi'])
    nt.links.new(ramp.outputs['Color'], b.inputs['Base Color'])
    return mat


def mat_ivory(pal):
    """Ivory plaque, very slightly cupped toward its own edges."""
    mat = new_mat("ivory")
    b = principled(mat)
    nt = mat.node_tree
    set_in(b, 'Metallic', 0.0)
    set_in(b, 'Roughness', 0.33)
    set_in(b, ['Coat Weight', 'Coat'], 0.45)
    set_in(b, ['Coat Roughness'], 0.10)
    genz, osep = coords(mat)
    rad = radial(nt, osep, 0.0, 0.22, 0.80, 0.62, 0.40, 1.15)
    fac = math_node(nt, 'MULTIPLY_ADD', None, -pal['ivory_radial'], 0.0)
    nt.links.new(rad, fac.inputs[0])
    nt.links.new(genz, fac.inputs[2])
    ramp = two_stop_ramp(nt, fac.outputs[0], pal['ivory_lo'], pal['ivory_hi'])
    nt.links.new(ramp.outputs['Color'], b.inputs['Base Color'])
    return mat


def mat_iron(pal, c=CFG):
    """Forged iron: a graphite body with a lit bevel on the bend's upper edge and a
    shadow on its lower edge, driven by the position across the bar."""
    mat = new_mat("iron")
    b = principled(mat)
    nt = mat.node_tree
    set_in(b, 'Metallic', 0.62)
    set_in(b, 'Roughness', 0.295)
    set_in(b, ['Coat Weight', 'Coat'], 0.25)
    set_in(b, ['Coat Roughness'], 0.16)
    a = math.radians(c['bar_angle'])
    nx, nz = -math.sin(a), math.cos(a)        # across the bar, toward the upper edge
    _, osep = coords(mat)
    px = math_node(nt, 'MULTIPLY', None, nx)
    nt.links.new(osep.outputs['X'], px.inputs[0])
    pz = math_node(nt, 'MULTIPLY', None, nz)
    nt.links.new(osep.outputs['Z'], pz.inputs[0])
    dot = math_node(nt, 'ADD')
    nt.links.new(px.outputs[0], dot.inputs[0])
    nt.links.new(pz.outputs[0], dot.inputs[1])
    off = nx * c['bar_cx'] + nz * c['bar_cz']
    rng = nt.nodes.new('ShaderNodeMapRange')
    rng.clamp = True
    rng.interpolation_type = 'SMOOTHSTEP'
    nt.links.new(dot.outputs[0], rng.inputs[0])
    rng.inputs[1].default_value = off - c['bar_half']
    rng.inputs[2].default_value = off + c['bar_half']
    rng.inputs[3].default_value = 0.0
    rng.inputs[4].default_value = 1.0
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.interpolation = 'EASE'
    ramp.color_ramp.elements[0].position = 0.0
    ramp.color_ramp.elements[0].color = pal['iron_dark'] + (1.0,)
    ramp.color_ramp.elements.new(0.34).color = pal['iron_body'] + (1.0,)
    ramp.color_ramp.elements.new(0.80).color = pal['iron_body'] + (1.0,)
    ramp.color_ramp.elements[3].position = 1.0
    ramp.color_ramp.elements[3].color = pal['iron_lit'] + (1.0,)
    nt.links.new(rng.outputs[0], ramp.inputs[0])
    nt.links.new(ramp.outputs['Color'], b.inputs['Base Color'])
    return mat


def mat_flat(name, color, rough=1.0):
    mat = new_mat(name)
    b = principled(mat)
    set_in(b, 'Base Color', color + (1.0,))
    set_in(b, 'Metallic', 0.0)
    set_in(b, 'Roughness', rough)
    set_in(b, ['Specular IOR Level', 'Specular'], 0.0)
    set_in(b, ['Coat Weight', 'Coat'], 0.0)
    return mat


def mat_backdrop(pal):
    mat = new_mat("backdrop")
    nt = mat.node_tree
    for n in list(nt.nodes):
        if n.type != 'OUTPUT_MATERIAL':
            nt.nodes.remove(n)
    out = next(n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL')

    coord = nt.nodes.new('ShaderNodeTexCoord')
    mapn = nt.nodes.new('ShaderNodeMapping')
    # Mapping (POINT) computes location + scale*p, so the centring offset is -scale/2.
    sc_ = 10.3
    # Z scale must be 0: Generated on a flat plane returns 0.5 on the degenerate
    # axis, which would push the SPHERICAL gradient past its falloff everywhere.
    mapn.inputs['Scale'].default_value = (sc_, sc_, 0.0)
    mapn.inputs['Location'].default_value = (-sc_ * 0.5, -sc_ * 0.5 - 0.34, 0.0)
    grad = nt.nodes.new('ShaderNodeTexGradient')
    for item in grad.bl_rna.properties['gradient_type'].enum_items:
        if item.identifier == 'SPHERICAL':
            grad.gradient_type = 'SPHERICAL'
            break
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.interpolation = 'EASE'
    ramp.color_ramp.elements[0].position = 0.00
    e = pal['bg_edge']
    ramp.color_ramp.elements[0].color = (e[0], e[1], e[2], 1.0)
    ramp.color_ramp.elements[1].position = 0.92
    g = pal['bg_glow']
    ramp.color_ramp.elements[1].color = (g[0], g[1], g[2], 1.0)

    nt.links.new(coord.outputs['Generated'], mapn.inputs['Vector'])
    nt.links.new(mapn.outputs['Vector'], grad.inputs['Vector'])
    nt.links.new(grad.outputs['Fac'], ramp.inputs['Fac'])

    diff = nt.nodes.new('ShaderNodeBsdfDiffuse')
    diff.inputs['Color'].default_value = pal['bg_diff'] + (1.0,)
    diff.inputs['Roughness'].default_value = 0.9
    emit = nt.nodes.new('ShaderNodeEmission')
    emit.inputs['Strength'].default_value = 0.80
    nt.links.new(ramp.outputs['Color'], emit.inputs['Color'])
    add = nt.nodes.new('ShaderNodeAddShader')
    nt.links.new(diff.outputs[0], add.inputs[0])
    nt.links.new(emit.outputs[0], add.inputs[1])
    nt.links.new(add.outputs[0], out.inputs['Surface'])
    return mat


# --------------------------------------------------------------------------- #
# scene
# --------------------------------------------------------------------------- #

def clear_scene():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)


def add_area(name, loc, target, size, energy, color):
    ld = bpy.data.lights.new(name, 'AREA')
    ld.size = size
    ld.energy = energy
    ld.color = color
    ob = bpy.data.objects.new(name, ld)
    bpy.context.collection.objects.link(ob)
    ob.location = loc
    d = Vector(target) - Vector(loc)
    ob.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    return ob


def build(pal, c=CFG):
    clear_scene()

    shield = shield_outline(c)
    field = offset_polygon(shield, c['rim'])
    bubble = bubble_outline(c)
    inner = offset_polygon(field, 0.004)
    bend, trim = bend_shapes(inner, c)
    halo = offset_polygon(shield, -c['halo_out'])

    hl = make_solid("contact_halo", halo, c['halo_y'], c['halo_t'], 0.010, 4)
    g = make_solid("gold_plate", shield, c['gold_y'], c['gold_t'], c['gold_bev'], 10)
    f = make_solid("enamel_field", field, c['field_y'], c['field_t'], c['field_bev'], 7)
    b = make_solid("speech_bubble", bubble, c['bubble_y'], c['bubble_t'], c['bubble_bev'], 7)
    tr = make_solid("bend_trim", trim, c['trim_y'], c['trim_t'], c['trim_bev'], 6)
    s = make_solid("bend_slash", bend, c['bar_y'], c['bar_t'], c['bar_bev'], 7)

    hl.data.materials.append(mat_flat("halo", pal['halo']))
    g.data.materials.append(mat_gold(pal, sweep=True))
    f.data.materials.append(mat_enamel(pal))
    b.data.materials.append(mat_ivory(pal))
    tr.data.materials.append(mat_gold(pal, sweep=False))
    s.data.materials.append(mat_iron(pal, c))

    # backdrop
    bpy.ops.mesh.primitive_plane_add(size=26.0, location=(0.0, 1.70, 0.0))
    bd = bpy.context.active_object
    bd.name = "backdrop"
    bd.rotation_euler = (math.radians(90.0), 0.0, 0.0)
    bd.data.materials.append(mat_backdrop(pal))

    # camera
    cam_d = c['frame_h'] * c['focal'] / 36.0
    cd = bpy.data.cameras.new("cam")
    cd.lens = c['focal']
    cd.sensor_fit = 'AUTO'
    cam = bpy.data.objects.new("cam", cd)
    bpy.context.collection.objects.link(cam)
    cam.location = (0.0, -cam_d, c['look_z'])
    cam.rotation_euler = (math.radians(90.0), 0.0, 0.0)
    bpy.context.scene.camera = cam

    # three-point lighting; the key is wide and soft so the top rim never blows out
    add_area("key", (-4.6, -5.4, 5.4), (-0.30, 0.0, 0.35), 8.0, 1010.0, (1.0, 0.960, 0.890))
    add_area("rim", (3.6, 1.9, 3.2), (0.70, 0.0, 0.25), 2.2, 940.0, (0.70, 0.82, 1.0))
    add_area("fill", (4.6, -5.6, -2.8), (0.35, 0.0, -0.35), 6.5, 200.0, (0.84, 0.89, 1.0))
    add_area("kick", (-3.4, -3.2, -4.2), (-0.35, 0.0, -1.05), 3.4, 310.0, (1.0, 0.78, 0.50))
    # broad, very soft wrap so the gold rim never falls to black anywhere on the ring
    add_area("wrap", (-2.2, -8.5, -0.6), (0.0, 0.0, -0.1), 12.0, 72.0, (1.0, 0.93, 0.84))

    w = bpy.context.scene.world
    if w is None:
        w = bpy.data.worlds.new("world")
        bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    bg = next((n for n in nt.nodes if n.type == 'BACKGROUND'), None)
    if bg:
        # A warm-floor / cool-sky environment. Gold is a mirror: with a black world it
        # renders as dull olive paint, so give it a graded environment to reflect.
        coord = nt.nodes.new('ShaderNodeTexCoord')
        sep = nt.nodes.new('ShaderNodeSeparateXYZ')
        rng = nt.nodes.new('ShaderNodeMapRange')
        env = nt.nodes.new('ShaderNodeValToRGB')
        nt.links.new(coord.outputs['Generated'], sep.inputs[0])
        nt.links.new(sep.outputs['Z'], rng.inputs[0])
        rng.inputs[1].default_value = -1.0
        rng.inputs[2].default_value = 1.0
        rng.inputs[3].default_value = 0.0
        rng.inputs[4].default_value = 1.0
        nt.links.new(rng.outputs[0], env.inputs['Fac'])
        cr = env.color_ramp
        cr.interpolation = 'EASE'
        cr.elements[0].position = 0.0
        cr.elements[0].color = pal['env_floor'] + (1.0,)
        mid = cr.elements.new(0.52)
        mid.color = pal['env_mid'] + (1.0,)
        cr.elements[2].position = 1.0
        cr.elements[2].color = pal['env_sky'] + (1.0,)
        nt.links.new(env.outputs['Color'], bg.inputs['Color'])
        bg.inputs['Strength'].default_value = 1.0


def setup_render(size, samples, view, look, exposure):
    sc = bpy.context.scene
    try:
        sc.render.engine = 'CYCLES'
    except TypeError as e:
        print("engine switch failed:", e)
    try:
        prefs = bpy.context.preferences.addons['cycles'].preferences
        chosen = None
        for ident in ('OPTIX', 'CUDA', 'HIP', 'ONEAPI'):
            try:
                prefs.compute_device_type = ident
                chosen = ident
                break
            except TypeError:
                continue
        try:
            prefs.get_devices()
        except Exception:
            pass
        for d in prefs.devices:
            d.use = (d.type != 'CPU')
        sc.cycles.device = 'GPU'
        print("cycles device type:", chosen)
    except Exception as e:
        print("gpu setup failed:", e)

    sc.cycles.samples = samples
    sc.cycles.seed = 0                 # pinned: renders must be reproducible
    sc.cycles.use_animated_seed = False
    sc.cycles.use_adaptive_sampling = True
    sc.cycles.adaptive_threshold = 0.01
    sc.cycles.use_denoising = True
    dn = sc.cycles.bl_rna.properties.get('denoiser')
    if dn:
        ids = [i.identifier for i in dn.enum_items]
        for pick in ('OPENIMAGEDENOISE', 'OPTIX'):
            if pick in ids:
                sc.cycles.denoiser = pick
                break
    sc.cycles.max_bounces = 8
    sc.cycles.caustics_reflective = True
    sc.cycles.blur_glossy = 0.6

    sc.render.resolution_x = size
    sc.render.resolution_y = size
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.render.filter_size = 1.25
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGB'
    sc.render.image_settings.color_depth = '8'
    sc.render.image_settings.compression = 15

    # These two enums are dynamic: bl_rna reports identifiers ("NONE") that the
    # setter rejects, and the legal Looks depend on the active view transform.
    # So: read the static list for diagnostics, then probe candidates.
    vs = sc.view_settings

    def try_set(prop, cands):
        for cand in cands:
            try:
                setattr(vs, prop, cand)
                return cand
            except TypeError:
                continue
        print("could not set", prop, "tried", cands, "static:",
              [i.identifier for i in vs.bl_rna.properties[prop].enum_items])
        return None

    print("view_transform ->", try_set('view_transform', [view, view.title(), 'Standard', 'AgX']))
    print("look ->", try_set('look', [look, look.title(), look.replace('AgX - ', ''),
                                      'AgX - ' + look, 'None', 'NONE']))
    vs.exposure = exposure


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = dict(out="out.png", size="1600", samples="300",
                view="Standard", look="None", exposure="0.0", palette="crimson")
    i = 0
    while i < len(argv):
        k = argv[i].lstrip('-')
        opts[k] = argv[i + 1]
        i += 2

    pal = dict(PAL)
    if opts['palette'] == 'azure':
        pal.update(PAL_AZURE)

    build(pal)
    setup_render(int(opts['size']), int(opts['samples']),
                 opts['view'], opts['look'], float(opts['exposure']))
    out = os.path.abspath(opts['out'])
    bpy.context.scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("WROTE", out)


if __name__ == "__main__":
    main()
