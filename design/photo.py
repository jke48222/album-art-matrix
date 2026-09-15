"""Photograph any saved model, every way the catalogue needs it.

One script instead of four, because the four generators each staged their own
scene and each lit it differently. This opens a saved .blend, throws away the
staging it came with, puts the new record on the panels, and shoots it in three
places: a dark cyclorama, the object's own gallery room, and a reconstruction of
the owner's actual bedroom.

    Blender --background --python design/photo.py -- \
        --blend design/renders/offset.blend --id offset \
        --out ../album-catalogue/shots --face design/wt192.png

Shots are skipped when the file already exists, so a run that dies part way
picks up where it stopped.
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy
from mathutils import Matrix, Vector

import my_room
import showroom

# ------------------------------------------------------------------ staging
STAGING = {
    "design": ("Studio",),
    "study": ("90 Studio", "91 Room", "92 Cameras", "93 Rear lighting"),
}
BACKDROP = {"Room wall", "Floor", "Studio sweep", "Wall", "Wall plane", "Sweep"}

# Collections that make up each photographable layer, in build order from the
# room inward. A model that has none of a group's collections just skips it.
LAYERS = [
    ("Glazing", ("__glass__",)),
    ("Front", ("Face",)),
    ("Panels", ("Panels", "P Panels", "09 Panels")),
    ("Carrier", ("__carrier__",)),
    ("Body", ("Body", "01 Exterior", "03 Chassis")),
    ("Electronics", ("Electronics", "E Power", "D Controller", "E Bus bars",
                     "U Unresolved fit", "05 Hardware", "11 Electronics")),
    ("Halo", ("Halo", "14 Halo")),
    ("Wiring", ("Wiring", "06 Wiring")),
]
GLASSY = ("acrylic", "glass", "glazing", "diffuser", "washi", "paper")
CARRIER = ("board", "steel skin", "steel", "plywood")
BACKPANEL = ("back panel", "rear cover", "04 rear cover", "back")


def clear_staging(kind):
    doomed = []
    for name in STAGING.get(kind, ()):
        c = bpy.data.collections.get(name)
        if c:
            doomed += list(c.objects)
    for o in bpy.data.objects:
        if o.type in ("LIGHT", "CAMERA"):
            doomed.append(o)
        elif o.type == "MESH" and o.name.split(".")[0] in BACKDROP:
            doomed.append(o)
    for o in set(doomed):
        bpy.data.objects.remove(o, do_unlink=True)
    for name in ("09 Dimensions", "Q Dimensions", "07 Labels"):
        c = bpy.data.collections.get(name)
        if c:
            c.hide_render = True


def new_record(face_png, led_png):
    """Put the new album on the panels.

    Two shapes exist in these files: a 192 square sampled by a shader that
    draws one disc per LED, and a 1536 square with the discs already baked in.
    Both are found by size, because the four generators named them differently.
    """
    face = bpy.data.images.load(os.path.abspath(face_png))
    led = bpy.data.images.load(os.path.abspath(led_png)) if os.path.exists(led_png) else face
    swapped = 0
    for mat in bpy.data.materials:
        if not mat.use_nodes:
            continue
        for node in mat.node_tree.nodes:
            if node.type != "TEX_IMAGE" or not node.image:
                continue
            w, h = node.image.size
            if w == h == 192:
                node.image = face
                swapped += 1
            elif w == h and w >= 512:
                node.image = led
                node.interpolation = "Closest"
                swapped += 1
    return swapped


HALO_GAIN = 2.4     # a 25 mm gap is a tight slot; it needs the output to read


def retint_halo(face_png, picture=0.48):
    """Give every halo strip the colour of the picture directly in front of it.

    The halo was built as twelve zones of an averaged, lifted and saturated edge
    colour, which is a mood light rather than a match. This runs after the model
    is moved so the picture's centre is the origin, works out from each strip's
    own position which edge it is on and where along it, samples the artwork's
    outer strip at exactly that point, and writes that colour back. Every design
    already carries 32 to 48 separate strips, each with its own material, so the
    resolution is there without touching any geometry.

    Hue and relative chroma are taken exactly. The only liberty is a floor: an
    album with a near-black edge would otherwise light nothing at all, so the
    brightest channel of a segment is lifted to 0.12 with the ratios kept.
    """
    img = bpy.data.images.load(os.path.abspath(face_png))
    w, h = img.size
    px = list(img.pixels)
    half = picture / 2.0
    d = max(3, w // 22)                      # the outer strip, about 5 per cent

    def sample(x0, x1, y0, y1):
        r = g = b = 0.0
        n = 0
        for y in range(max(0, y0), min(h, y1)):
            row = y * w
            for x in range(max(0, x0), min(w, x1)):
                i = (row + x) * 4
                r += px[i]
                g += px[i + 1]
                b += px[i + 2]
                n += 1
        if not n:
            return (0.12, 0.12, 0.12)
        r, g, b = r / n, g / n, b / n
        mx = max(r, g, b)
        if mx < 0.30:                        # a dark edge still has to make light
            k = 0.30 / max(mx, 1e-4)
            r, g, b = r * k, g * k, b * k
        return (min(1.0, r), min(1.0, g), min(1.0, b))

    done = 0
    gained = set()
    for o in bpy.data.objects:
        emitters = []
        if o.type == "MESH" and o.data.materials:
            for m in o.data.materials:
                if not m or not m.use_nodes:
                    continue
                for node in m.node_tree.nodes:
                    if node.type == "BSDF_PRINCIPLED" and \
                            node.inputs["Emission Strength"].default_value > 0:
                        emitters.append(node.inputs["Emission Color"])
                    elif node.type == "EMISSION":
                        emitters.append(node.inputs["Color"])
        elif o.type == "LIGHT":
            emitters.append(o)
        if not emitters:
            continue
        n = o.name.lower()
        in_halo_col = any(c.name.split(".")[0] in ("Halo", "14 Halo")
                          for c in o.users_collection)
        # wall_model puts its strips in the Board collection and the study puts
        # its in 14 Halo, so the name is the only thing all four agree on
        by_name = (n.startswith("halo") or "rear facing led strip" in n
                   or "edge-sampled" in n or "edge sample" in n)
        if not (in_halo_col or by_name):
            continue
        p = o.matrix_world.translation
        x, z = p.x, p.z
        span = max(abs(x), abs(z), 1e-6)
        for e in emitters:
            if hasattr(e, "node") and e.node.type == "BSDF_PRINCIPLED":
                if id(e.node) in gained:
                    continue
                gained.add(id(e.node))
                e.node.inputs["Emission Strength"].default_value *= HALO_GAIN
        if abs(x) >= abs(z):                 # a left or right strip: read up the side
            v = min(1.0, max(0.0, (z + half) / picture))
            y = int(v * (h - 1))
            if x > 0:
                col = sample(w - d, w, y - d // 2, y + d // 2 + 1)
            else:
                col = sample(0, d, y - d // 2, y + d // 2 + 1)
        else:                                # a top or bottom strip: read across
            u = min(1.0, max(0.0, (x + half) / picture))
            xx = int(u * (w - 1))
            if z > 0:
                col = sample(xx - d // 2, xx + d // 2 + 1, h - d, h)
            else:
                col = sample(xx - d // 2, xx + d // 2 + 1, 0, d)
        for e in emitters:
            if hasattr(e, "default_value"):
                e.default_value = (*col, 1.0)
            else:
                e.data.color = col
        done += 1
    print("halo retinted", done, "strips", flush=True)
    return done


def polish():
    """Break the roughness of the big flat surfaces.

    A body painted or machined to one exact roughness everywhere is the thing
    that reads as a render rather than as an object. This puts a few per cent of
    procedural variation on any opaque, non-emissive material that does not
    already drive its own roughness, which is most of them.
    """
    touched = 0
    for mat in bpy.data.materials:
        if not mat.use_nodes:
            continue
        nt = mat.node_tree
        for node in nt.nodes:
            if node.type != "BSDF_PRINCIPLED":
                continue
            rough = node.inputs["Roughness"]
            if rough.is_linked or rough.default_value < 0.12:
                continue
            if node.inputs["Emission Strength"].default_value > 0:
                continue
            t = node.inputs.get("Transmission Weight")
            if t is not None and t.default_value > 0.2:
                continue
            base = rough.default_value
            tex = nt.nodes.new("ShaderNodeTexNoise")
            tex.inputs["Scale"].default_value = 220.0
            tex.inputs["Detail"].default_value = 5.0
            tex.inputs["Roughness"].default_value = 0.6
            rng = nt.nodes.new("ShaderNodeMapRange")
            rng.inputs["From Min"].default_value = 0.25
            rng.inputs["From Max"].default_value = 0.75
            rng.inputs["To Min"].default_value = max(0.02, base - 0.055)
            rng.inputs["To Max"].default_value = min(1.0, base + 0.055)
            nt.links.new(tex.outputs["Fac"], rng.inputs["Value"])
            nt.links.new(rng.outputs["Result"], rough)
            touched += 1
    print("polished", touched, "materials", flush=True)


# Hardware that is real but does not belong in a picture of the object.
HIDE_IN_ROOM = ("power cord", "wall drop")


def tuck_strays():
    """Pull parts that poke out of the body back inside it.

    Two different escapes, both of which read as faults rather than as detail.
    A part can stand outside the whole silhouette, and a part that lives behind
    the picture can push sideways through a rail and appear on the outside of a
    finished object: Wall III's +5V and ground terminals came through the right
    rail and sat there in bright red, which is the same class of fault as the
    light sensor that used to sit on the artwork.

    So there are two limits. Anything small is kept inside the silhouette the
    big parts make. Anything small that lives wholly behind the picture plane is
    kept inside the picture's own footprint, since that is the cavity it belongs
    in. Depth is never touched, because standing proud of the back is the whole
    point of a cleat.
    """
    parts = []
    for o in bpy.data.objects:
        if o.type != "MESH" or not visible(o) or not o.data.vertices:
            continue
        ws = [o.matrix_world @ v.co for v in o.data.vertices]
        lo = Vector((min(v.x for v in ws), min(v.y for v in ws), min(v.z for v in ws)))
        hi = Vector((max(v.x for v in ws), max(v.y for v in ws), max(v.z for v in ws)))
        parts.append((o, lo, hi, max(hi.x - lo.x, hi.z - lo.z)))
    if not parts:
        return
    span = max(p[3] for p in parts)
    body = [p for p in parts if p[3] > span * 0.30]
    if not body:
        return
    lx = max(max(abs(p[1].x), abs(p[2].x)) for p in body)
    lz = max(max(abs(p[1].z), abs(p[2].z)) for p in body)

    inner_x = inner_z = None
    for n in ("P Panels", "09 Panels", "Panels"):
        c = bpy.data.collections.get(n)
        if c and len(c.objects):
            plo, phi = bounds([o for o in c.objects if visible(o)])
            if plo:
                # halfway between the picture and the outside edge: tight
                # enough to keep hardware out of the rails, loose enough that
                # the pack does not get shoved around inside its own cavity
                inner_x = (max(abs(plo.x), abs(phi.x)) + lx) / 2
                inner_z = (max(abs(plo.z), abs(phi.z)) + lz) / 2
                break

    moved = 0
    for o, lo, hi, size in parts:
        if size > span * 0.18:
            continue
        # a part wholly behind the picture belongs in the cavity, not the rail
        cx, cz = lx, lz
        if inner_x and lo.y > 0.02:
            cx, cz = inner_x, inner_z
        dx = dz = 0.0
        if hi.x > cx:
            dx = cx - hi.x - 0.002
        elif lo.x < -cx:
            dx = -cx - lo.x + 0.002
        if hi.z > cz:
            dz = cz - hi.z - 0.002
        elif lo.z < -cz:
            dz = -cz - lo.z + 0.002
        if not (dx or dz):
            continue
        d = Vector((dx, 0.0, dz))
        if o.parent:            # location is parent space, the delta is world
            d = o.parent.matrix_world.to_3x3().inverted() @ d
        o.location += d
        moved += 1
    if moved:
        print("tucked", moved, "stray parts inside the body", flush=True)


WOODY = ("walnut", "oak", "poplar", "wood", "timber", "ply", "birch", "maple",
         "veneer")


def grain():
    """Put real grain in anything made of wood, running the right way.

    Two faults, both of which made every wooden part read as flat plastic.
    The first is units: the walnut was driven from Object coordinates at a
    frequency that assumes metres, and these models are in millimetres, so each
    band came out a fraction of a millimetre wide and averaged to nothing.
    Generated coordinates run 0 to 1 across a part's own bounding box whatever
    the units are.

    The second is direction. Grain runs along a rail, and a mitred frame has
    four rails pointing three different ways, so one shared material stretched
    along a fixed axis is wrong for most of them. This works per object: it
    finds each part's longest axis, and gives that axis a low frequency and the
    two cross axes a high one, so the figure always runs lengthwise. Materials
    are copied per axis, so a frame ends up with at most three of them.

    Where a material already carries a colour ramp its colours are kept, since
    those were chosen; only the coordinates and the frequency change.
    """
    made = {}
    touched = 0

    def variant(mat, axis):
        key = (mat.name, axis)
        if key in made:
            return made[key]
        m = mat.copy()
        m.name = "%s grain %s" % (mat.name, "xyz"[axis])
        made[key] = m
        nt = m.node_tree
        for node in nt.nodes:
            if node.type != "BSDF_PRINCIPLED":
                continue
            base = node.inputs["Base Color"]
            dark = light = None
            if base.is_linked:
                seen, stack = set(), [base.links[0].from_node]
                while stack:                      # keep the colours it had
                    n = stack.pop()
                    if id(n) in seen:
                        continue
                    seen.add(id(n))
                    if n.type == "VALTORGB":
                        dark = tuple(n.color_ramp.elements[0].color)
                        light = tuple(n.color_ramp.elements[-1].color)
                        break
                    for i in n.inputs:
                        if i.is_linked:
                            stack.append(i.links[0].from_node)
                for l in list(base.links):
                    nt.links.remove(l)
            if dark is None:
                r, g, b, a = base.default_value
                dark = (r * 0.70, g * 0.66, b * 0.62, a)
                light = (min(1, r * 1.24), min(1, g * 1.20), min(1, b * 1.15), a)

            # along the length the figure wanders; across the face it bands
            sc = [11.0, 11.0, 11.0]
            sc[axis] = 3.0

            co = nt.nodes.new("ShaderNodeTexCoord")
            mp = nt.nodes.new("ShaderNodeMapping")
            mp.inputs["Scale"].default_value = tuple(sc)
            nt.links.new(co.outputs["Generated"], mp.inputs["Vector"])

            fig = nt.nodes.new("ShaderNodeTexNoise")
            fig.inputs["Scale"].default_value = 1.0
            fig.inputs["Detail"].default_value = 9.0
            fig.inputs["Roughness"].default_value = 0.58
            nt.links.new(mp.outputs["Vector"], fig.inputs["Vector"])

            ramp = nt.nodes.new("ShaderNodeValToRGB")
            cr = ramp.color_ramp
            cr.elements[0].position = 0.33
            cr.elements[0].color = dark
            cr.elements[1].position = 0.70
            cr.elements[1].color = light
            cr.elements.new(0.51).color = tuple((d + l) / 2 for d, l in zip(dark, light))
            nt.links.new(fig.outputs["Fac"], ramp.inputs["Fac"])
            nt.links.new(ramp.outputs["Color"], base)

            pore = nt.nodes.new("ShaderNodeTexNoise")
            pore.inputs["Scale"].default_value = 3.4
            pore.inputs["Detail"].default_value = 4.0
            nt.links.new(mp.outputs["Vector"], pore.inputs["Vector"])
            bump = nt.nodes.new("ShaderNodeBump")
            bump.inputs["Strength"].default_value = 0.18
            nt.links.new(pore.outputs["Fac"], bump.inputs["Height"])
            for l in list(node.inputs["Normal"].links):
                nt.links.remove(l)
            nt.links.new(bump.outputs["Normal"], node.inputs["Normal"])
        return m

    for o in bpy.data.objects:
        if o.type != "MESH" or not o.data.materials:
            continue
        d = o.dimensions
        axis = max(range(3), key=lambda i: d[i])
        for i, mat in enumerate(o.data.materials):
            if mat and any(w in mat.name.lower() for w in WOODY) and "grain" not in mat.name:
                o.data.materials[i] = variant(mat, axis)
                touched += 1
    print("grained", touched, "parts,", len(made), "materials", flush=True)


# ------------------------------------------------------------------- emission
def collect_emitters():
    """Every material that makes light, with the strength it was built at."""
    out = []
    for mat in bpy.data.materials:
        if not mat.use_nodes:
            continue
        for node in mat.node_tree.nodes:
            if node.type == "BSDF_PRINCIPLED" and "Emission Strength" in node.inputs:
                v = node.inputs["Emission Strength"].default_value
                if v > 0:
                    out.append((node.inputs["Emission Strength"], v))
            elif node.type == "EMISSION":
                v = node.inputs["Strength"].default_value
                if v > 0:
                    out.append((node.inputs["Strength"], v))
    return out


def collect_halo_lights():
    out = []
    for o in bpy.data.objects:
        if o.type != "LIGHT":
            continue
        if any(c.name.split(".")[0] in ("Halo", "14 Halo") for c in o.users_collection):
            out.append((o, o.data.energy))
    return out


def set_power(emitters, factor, lights=()):
    for socket, base in emitters:
        socket.default_value = base * factor
    for o, base in lights:
        o.data.energy = base * factor


# --------------------------------------------------------------------- bounds
NOT_THE_OBJECT = ("Studio", "My room", "TEMP", "99 Temporary")


def visible(o):
    if o.type != "MESH" or o.hide_render or not o.data.vertices:
        return False
    for c in o.users_collection:
        if c.hide_render or c.name.startswith("Cutters"):
            return False
        if any(c.name.split(".")[0] == n for n in NOT_THE_OBJECT):
            return False
    return True


def bounds(objs):
    lo, hi = Vector((1e9,) * 3), Vector((-1e9,) * 3)
    n = 0
    for o in objs:
        n += 1
        for corner in o.bound_box:
            w = o.matrix_world @ Vector(corner)
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
    return (lo, hi) if n else (None, None)


def anchor(kind):
    """Where to move the model so its picture centre is the world origin, its
    rear face is on y = 0 and it stands upright."""
    objs = [o for o in bpy.data.objects if visible(o)]
    lo, hi = bounds(objs)
    panels = None
    for n in ("P Panels", "09 Panels", "Panels"):
        c = bpy.data.collections.get(n)
        if c and len(c.objects):
            p = bounds([o for o in c.objects if visible(o)])
            if p[0]:
                panels = p
                break
    if panels:
        plo, phi = panels
        cx, cz = (plo.x + phi.x) / 2, (plo.z + phi.z) / 2
    else:
        cx, cz = (lo.x + hi.x) / 2, (lo.z + hi.z) / 2
    return Vector((cx, hi.y, cz)), (lo, hi)


def roots():
    return [o for o in bpy.data.objects if o.parent is None and o.type in ("EMPTY", "MESH", "CURVE", "FONT")]


# ------------------------------------------------------------------ the studio
class Studio:
    """A dark cyclorama. Everything that is not a room shot happens here."""

    def __init__(self, span, depth):
        self.col = bpy.data.collections.new("Studio")
        bpy.context.scene.collection.children.link(self.col)
        self.span, self.depth = span, depth
        sweep = self._sweep(span)
        self.lights = {}
        self._light(span)
        self.sweep = sweep
        world = bpy.data.worlds.new("Dark")
        world.use_nodes = True
        world.node_tree.nodes["Background"].inputs[0].default_value = (0.055, 0.058, 0.070, 1)
        world.node_tree.nodes["Background"].inputs[1].default_value = 0.045
        bpy.context.scene.world = world

    def _sweep(self, span):
        """A wall that curves into a floor, so the object sits in a gradient
        with no horizon line behind it. The object's back is on y = 0, so the
        wall stands a little behind that and the floor runs toward the camera."""
        wy = span * 0.10
        fz = -span * 0.95
        R = span * 0.55
        n = 24
        prof = [(wy, span * 2.4), (wy, fz + R)]
        for i in range(1, n + 1):
            t = math.radians(90 * i / n)
            prof.append((wy - R + R * math.cos(t), fz + R - R * math.sin(t)))
        prof.append((wy - R - span * 4.0, fz))
        w = span * 8
        verts, faces = [], []
        for y, z in prof:
            verts += [(-w / 2, y, z), (w / 2, y, z)]
        for i in range(len(prof) - 1):
            a = i * 2
            faces.append((a, a + 1, a + 3, a + 2))
        me = bpy.data.meshes.new("Sweep")
        me.from_pydata(verts, [], faces)
        me.update()
        for pgon in me.polygons:
            pgon.use_smooth = True
        o = bpy.data.objects.new("Sweep", me)
        m = bpy.data.materials.new("Cyclorama")
        m.use_nodes = True
        b = m.node_tree.nodes.get("Principled BSDF")
        b.inputs["Base Color"].default_value = (0.048, 0.049, 0.055, 1)
        b.inputs["Roughness"].default_value = 0.70
        me.materials.append(m)
        self.col.objects.link(o)
        return o

    def _area(self, name, loc, target, power, size, colour=(1, 1, 1), size_y=None):
        d = bpy.data.lights.new(name, "AREA")
        d.energy, d.size, d.color = power, size, colour
        if size_y:
            d.shape, d.size_y = "RECTANGLE", size_y
        o = bpy.data.objects.new(name, d)
        self.col.objects.link(o)
        o.location = loc
        o.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        o.visible_camera = False
        self.lights[name] = o
        return o

    def _light(self, s):
        self._area("key", (-s * 1.5, -s * 1.9, s * 1.5), (0, 0, 0), 260 * s * s, s * 1.5,
                   (1.0, 0.95, 0.88))
        self._area("fill", (s * 1.9, -s * 2.2, -s * 0.4), (0, 0, 0), 55 * s * s, s * 1.8,
                   (0.80, 0.86, 1.0))
        self._area("rim", (s * 1.35, s * 0.9, s * 1.25), (0, 0, 0), 150 * s * s, s * 0.7,
                   (0.92, 0.95, 1.0))
        self._area("back", (0, s * 2.4, s * 0.4), (0, 0, 0), 240 * s * s, s * 1.6,
                   (0.95, 0.96, 1.0))
        self._area("floor", (0, -s * 1.1, -s * 1.5), (0, 0, 0), 30 * s * s, s * 1.4,
                   (1.0, 0.88, 0.72))
        self.lights["back"].hide_render = True

    def mood(self, name):
        """Named lighting states. `dark` is the object lighting itself."""
        on = {
            "product": {"key": 1.0, "fill": 1.0, "rim": 1.0, "floor": 1.0, "back": 0.0},
            "cinematic": {"key": 0.34, "fill": 0.18, "rim": 1.5, "floor": 0.35, "back": 0.0},
            "dark": {"key": 0.0, "fill": 0.05, "rim": 0.30, "floor": 0.0, "back": 0.0},
            "rake": {"key": 0.10, "fill": 0.06, "rim": 2.4, "floor": 0.10, "back": 0.0},
            "back": {"key": 0.22, "fill": 0.40, "rim": 0.30, "floor": 0.15, "back": 0.55},
            "flat": {"key": 0.9, "fill": 0.9, "rim": 0.7, "floor": 0.6, "back": 0.4},
        }[name]
        for k, o in self.lights.items():
            o.hide_render = on.get(k, 0.0) <= 0.0
            if not o.hide_render:
                if "base" not in o:
                    o["base"] = o.data.energy
                o.data.energy = o["base"] * on[k]
        return self


# ------------------------------------------------------------------- cameras
def camera(name, pos, target, lens=55.0, fstop=None, focus=None, ortho=None):
    d = bpy.data.cameras.new(name)
    d.lens = lens
    d.clip_start, d.clip_end = 0.002, 400
    if ortho:
        d.type = "ORTHO"
        d.ortho_scale = ortho
    if fstop:
        d.dof.use_dof = True
        d.dof.aperture_fstop = fstop
        d.dof.focus_distance = (Vector(focus or target) - Vector(pos)).length
    o = bpy.data.objects.new(name, d)
    bpy.context.scene.collection.objects.link(o)
    o.location = pos
    o.rotation_euler = (Vector(target) - o.location).to_track_quat("-Z", "Y").to_euler()
    return o


def fit(direction, lens, extent, res, target=(0, 0, 0)):
    """Stand the camera where `extent` metres fills the short axis of the frame.

    The first pass placed cameras at hand-picked multiples of the object's size
    and every one of them was a macro of the LED grid: at 62 mm and a metre
    away a 36 mm sensor sees 580 mm, which is the object exactly and no frame
    around it. This computes the distance instead."""
    w, h = res
    d = extent * lens / (36.0 * min(1.0, h / w))
    return tuple(Vector(target) + Vector(direction).normalized() * d)


# ------------------------------------------------------------- creative shots
# One or two angles that only make sense for that particular object.
# (label, direction, target as a fraction of the bounding box, lens, how much of
# the object fills the short axis, f-stop, lighting)
CREATIVE = {
    "offset":  [("steps",   (-0.9, -1.0, 0.7), (-0.30, 0.0, 0.30), 100, 0.63, 7.0, "rake"),
                ("edge",    (1.5, -1.0, -0.1), (0.30, 0.0, 0.0), 85, 1.02, 8.8, "cinematic")],
    "cove":    [("throat",  (-0.5, -1.0, 1.0), (0.0, 0.0, 0.0), 70, 1.25, 9.9, "cinematic"),
                ("graze",   (1.2, -0.7, 0.9), (0.20, 0.0, 0.15), 100, 0.83, 7.7, "rake")],
    "ply":     [("plies",   (-0.9, -1.0, 0.8), (-0.32, 0.0, 0.32), 110, 0.52, 6.3, "rake"),
                ("bevel",   (0.0, -1.0, 0.9), (0.0, 0.0, 0.26), 95, 0.78, 7.0, "cinematic")],
    "section": [("mitre",   (-1.0, -1.0, 1.0), (-0.36, 0.0, 0.36), 105, 0.48, 6.6, "rake"),
                ("plate",   (0.9, -1.0, 0.3), (0.10, 0.0, 0.0), 80, 1.15, 8.8, "cinematic")],
    "wall-3":  [("brass",   (-0.45, -1.0, -0.10), (0.0, 0.0, -0.86), 85, 0.72, 8.0, "product"),
                ("reveal",  (0.0, -1.0, 0.8), (0.0, 0.0, 0.24), 95, 0.81, 7.7, "cinematic")],
    "wall-6c": [("standoff", (1.0, -1.0, 0.9), (0.34, 0.0, 0.34), 110, 0.48, 6.3, "rake"),
                ("mat",     (0.0, -1.0, -0.5), (0.0, 0.0, -0.14), 85, 1.11, 8.8, "cinematic")],
    "index":   [("flank",   (1.6, -1.0, 0.2), (0.0, 0.0, 0.0), 85, 1.25, 8.8, "cinematic"),
                ("seam",    (-1.0, -1.0, 0.9), (-0.34, 0.0, 0.34), 105, 0.52, 6.6, "rake")],
    "soft":    [("facet",   (-1.1, -1.0, 0.8), (-0.34, 0.0, 0.30), 90, 0.78, 7.7, "rake"),
                ("shoe",    (-0.40, -1.0, -0.30), (-0.34, 0.0, -0.86), 80, 0.80, 8.0, "product")],
    "splay":   [("funnel",  (-0.6, -1.0, 0.5), (0.0, 0.0, 0.0), 60, 1.25, 11.0, "dark"),
                ("bloom",   (0.9, -1.0, 0.5), (0.0, 0.0, 0.0), 75, 1.15, 4.0, "cinematic")],
    "case":    [("proud",   (-0.9, -1.0, 0.9), (-0.30, 0.0, 0.30), 110, 0.48, 6.3, "rake"),
                ("wool",    (0.8, -1.0, -0.7), (0.18, 0.0, -0.26), 95, 0.67, 7.0, "cinematic")],
    "strap":   [("ring",    (-0.9, -1.0, 0.9), (-0.28, 0.0, 0.30), 110, 0.48, 6.3, "rake"),
                ("corner",  (1.0, -1.0, -0.9), (0.34, 0.0, -0.32), 105, 0.52, 6.6, "cinematic")],
    # round six: one named change each, so they keep their parent's angles
    "wall-6d":   [("standoff", (1.0, -1.0, 0.9), (0.34, 0.0, 0.34), 110, 0.48, 6.3, "rake"),
                  ("mat",     (0.0, -1.0, -0.5), (0.0, 0.0, -0.14), 85, 1.11, 8.8, "cinematic")],
    "cove-2":    [("throat",  (-0.5, -1.0, 1.0), (0.0, 0.0, 0.0), 70, 1.25, 9.9, "cinematic"),
                  ("graze",   (1.2, -0.7, 0.9), (0.20, 0.0, 0.15), 100, 0.83, 7.7, "rake")],
    "ply-2":     [("plies",   (-0.9, -1.0, 0.8), (-0.32, 0.0, 0.32), 110, 0.52, 6.3, "rake"),
                  ("bevel",   (0.0, -1.0, 0.9), (0.0, 0.0, 0.26), 95, 0.78, 7.0, "cinematic")],
    "section-2": [("mitre",   (-1.0, -1.0, 1.0), (-0.36, 0.0, 0.36), 105, 0.48, 6.6, "rake"),
                  ("plate",   (0.9, -1.0, 0.3), (0.10, 0.0, 0.0), 80, 1.15, 8.8, "cinematic")],
    "shutter": [("kumiko",  (-1.0, -1.0, 0.8), (-0.44, 0.0, 0.26), 100, 0.59, 6.6, "rake"),
                ("wing",    (-1.4, -1.0, 0.3), (-0.30, 0.0, 0.05), 60, 1.05, 4.5, "cinematic")],
}


# ------------------------------------------------------------------- the shoot
def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--blend", required=True)
    ap.add_argument("--id", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--face", default="design/wt192.png")
    ap.add_argument("--led", default="design/wt-led.png")
    ap.add_argument("--kind", default="design", choices=("design", "study"))
    ap.add_argument("--res", type=int, default=1500)
    ap.add_argument("--samples", type=int, default=220)
    ap.add_argument("--vframes", type=int, default=8)
    ap.add_argument("--only", default="")
    ap.add_argument("--look", default="grey",
                    choices=("submerged", "prima", "tintype", "grey"),
                    help="which showroom this object gets")
    ap.add_argument("--soften", action="store_true",
                    help="roughen the glazing so it stops mirroring the sweep")
    args = ap.parse_args(argv)

    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    only = set(args.only.split(",")) if args.only else None

    bpy.ops.wm.open_mainfile(filepath=os.path.abspath(args.blend))
    clear_staging(args.kind)
    print("record swapped into", new_record(args.face, args.led), "textures", flush=True)

    off, (lo, hi) = anchor(args.kind)
    for r in roots():
        r.location = (r.location[0] - off.x, r.location[1] - off.y, r.location[2] - off.z)
    bpy.context.view_layer.update()
    lo, hi = bounds([o for o in bpy.data.objects if visible(o)])
    span = max(hi.x - lo.x, hi.z - lo.z)
    depth = hi.y - lo.y
    print(f"envelope {span*1000:.0f} mm, depth {depth*1000:.0f} mm", flush=True)

    if args.soften:
        for mat in bpy.data.materials:
            if not mat.use_nodes:
                continue
            for node in mat.node_tree.nodes:
                if node.type != "BSDF_PRINCIPLED":
                    continue
                t = node.inputs.get("Transmission Weight")
                if t is not None and t.default_value > 0.3:
                    r = node.inputs["Roughness"]
                    r.default_value = max(r.default_value, 0.11)

    polish()
    grain()
    tuck_strays()
    retint_halo(args.face)
    emitters = collect_emitters()
    halo_lights = collect_halo_lights()
    studio = Studio(span, depth)

    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.samples = args.samples
    sc.cycles.use_denoising = True
    sc.cycles.adaptive_threshold = 0.012
    sc.cycles.max_bounces = 12
    sc.cycles.transmission_bounces = 8
    sc.cycles.caustics_reflective = True
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = (d.type == "METAL")
        sc.cycles.device = "GPU"
    except Exception:
        pass
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGB"
    sc.render.film_transparent = False
    sc.view_settings.view_transform = "AgX"
    try:
        sc.view_settings.look = "AgX - Medium High Contrast"
    except Exception:
        pass
    # A little bloom off the LEDs. Blender 5 hangs the compositor off the scene
    # as a node group, and wall_model.glare already knows that; reuse it rather
    # than write the same fallback twice.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import wall_model as W
    W.glare(sc)

    def shoot(name, res=None, aspect=None):
        path = os.path.join(out, f"{args.id}-{name}.png")
        if only and name not in only:
            return
        if os.path.exists(path):
            print("have", name, flush=True)
            return
        w, h = res or (args.res, int(args.res * 0.72))
        if aspect:
            w, h = aspect
        sc.render.resolution_x, sc.render.resolution_y = w, h
        sc.render.filepath = path
        bpy.ops.render.render(write_still=True)
        print("shot", name, flush=True)

    # ---------------------------------------------------------- the studio set
    s, d = span, depth
    set_power(emitters, 1.0, halo_lights)
    WIDE = (int(args.res * 1.28), int(args.res * 0.90))
    STD = (args.res, int(args.res * 0.72))
    SQ = (args.res, args.res)

    def use(cam, mood):
        sc.camera = cam
        studio.mood(mood)

    FLOOR_Z = -s * 0.95 + 0.06

    def shot(name, direction, lens, fill, mood, res=STD, fstop=None, target=(0, 0, 0)):
        t = (target[0] * s / 2, target[1] * d, target[2] * s / 2)
        pos = fit(direction, lens, s * fill, res, t)
        pos = (pos[0], pos[1], max(pos[2], FLOOR_Z))
        use(camera(name, pos, t, lens, fstop, focus=t), mood)
        shoot(name, res=res)

    studio.sweep.hide_render = False
    shot("hero", (-0.62, -1.0, 0.26), 55, 1.45, "product", STD, 6.3)
    shot("front", (0.0, -1.0, 0.0), 85, 1.16, "product", SQ)
    shot("side", (1.0, -0.30, 0.03), 60, 1.28, "product", STD, 11)

    k = (lo.x + s * 0.045, lo.y, hi.z - s * 0.045)
    kc = fit((-0.55, -0.85, 0.42), 95, s * 0.52, STD, k)
    kc = (kc[0], kc[1], max(kc[2], FLOOR_Z))
    use(camera("corner", kc, k, 95, 7.1, focus=k), "rake")
    shoot("corner")

    # The four finalists were renamed, and CREATIVE is keyed by what they used
    # to be called, so without this every one of them silently lost the two
    # shots the brief asks for by name.
    RENAMED = {"obsidian": "wall-6d", "alabaster": "cove-2",
               "heartwood": "wall-3", "argent": "index"}
    creative = CREATIVE.get(args.id) or CREATIVE.get(RENAMED.get(args.id, ""), [])
    for label, direction, tgt, lens, fill, fstop, mood in creative[:2]:
        shot(label, direction, lens, fill, mood, STD, fstop, tgt)

    # ------------------------------------------------------------ backs
    backs = [o for o in bpy.data.objects
             if o.type == "MESH" and any(b in o.name.lower() for b in BACKPANEL)]
    bpos = fit((0.55, 1.0, 0.34), 48, s * 1.45, STD)
    studio.sweep.hide_render = True          # it stands between the camera and the back
    use(camera("back", bpos, (0, 0, 0), 48), "back")
    shoot("back-covered")
    for o in backs:
        o.hide_render = True
    shoot("back-exposed")
    for o in backs:
        o.hide_render = False
    studio.sweep.hide_render = False

    # ------------------------------------------------------------ exploded
    groups = []
    for label, names in LAYERS:
        objs = []
        if names[0] == "__glass__":
            objs = [o for o in bpy.data.objects
                    if visible(o) and any(g in o.name.lower() for g in GLASSY)]
        elif names[0] == "__carrier__":
            objs = [o for o in bpy.data.objects
                    if visible(o) and any(g in o.name.lower() for g in CARRIER)]
        else:
            for n in names:
                c = bpy.data.collections.get(n)
                if c:
                    objs += [o for o in c.objects if visible(o)]
        if objs:
            groups.append((label, list(dict.fromkeys(objs))))

    seen, clean = set(), []
    for label, objs in groups:
        fresh = [o for o in objs if o.name not in seen]
        for o in fresh:
            seen.add(o.name)
        if fresh:
            clean.append((label, fresh))
    groups = clean

    step = max(span * 0.17, 0.055)
    saved = {o.name: tuple(o.location) for _, objs in groups for o in objs}

    def explode(on):
        for i, (_, objs) in enumerate(groups):
            dy = (len(groups) - 1 - i) * step * (1 if on else 0)
            for o in objs:
                base = Vector(saved[o.name])
                if not dy:
                    o.location = base
                    continue
                basis = (o.parent.matrix_world.to_3x3() if o.parent else Matrix.Identity(3))
                o.location = base + basis.inverted() @ Vector((0.0, -dy, 0.0))
        bpy.context.view_layer.update()

    explode(True)
    elo, ehi = bounds([o for o in bpy.data.objects if visible(o)])
    ec = ((elo.x + ehi.x) / 2, (elo.y + ehi.y) / 2, (elo.z + ehi.z) / 2)
    esp = max(ehi.x - elo.x, ehi.z - elo.z, (ehi.y - elo.y) * 0.75)
    use(camera("exf", fit((-0.75, -1.0, 0.38), 52, esp * 1.30, WIDE, ec), ec, 52), "flat")
    shoot("exploded-front", res=WIDE)
    studio.sweep.hide_render = True
    use(camera("exb", fit((0.80, 1.0, 0.36), 52, esp * 1.30, WIDE, ec), ec, 52), "back")
    shoot("exploded-back", res=WIDE)
    studio.sweep.hide_render = False
    explode(False)

    # ------------------------------------------------------------ each layer
    everything = [o for o in bpy.data.objects if visible(o)]
    LAYER_RES = (1180, 850)
    for i, (label, objs) in enumerate(groups):
        keep = set(o.name for o in objs)
        for o in everything:
            o.hide_render = o.name not in keep
        llo, lhi = bounds(objs)
        lc = ((llo.x + lhi.x) / 2, (llo.y + lhi.y) / 2, (llo.z + lhi.z) / 2)
        lsp = max(lhi.x - llo.x, lhi.z - llo.z, 0.05)
        use(camera(f"layer{i}", fit((-0.5, -1.0, 0.28), 55, lsp * 1.30, LAYER_RES, lc), lc, 55),
            "flat")
        shoot(f"layer-{i + 1}-{label.lower()}", res=LAYER_RES)
    for o in everything:
        o.hide_render = False

    # ------------------------------------------------------------ its own room
    # The staged photograph, the dark one and the loop all happen here now. A
    # cyclorama is right for a technical view and wrong for the picture that
    # leads the page, and this room is art directed to the record on the panel.
    studio.sweep.hide_render = True
    for o in studio.lights.values():
        o.hide_render = True
    hidden_here = [o for o in bpy.data.objects
                   if any(k in o.name.lower() for k in HIDE_IN_ROOM)]
    for o in hidden_here:
        o.hide_render = True
    if hidden_here:
        print("hidden for the room:", ", ".join(o.name for o in hidden_here), flush=True)
    show = showroom.Room(args.look).build()
    ROOM_W = (int(args.res * 1.30), int(args.res * 0.88))
    ROOM_SQ = (int(args.res * 1.02), int(args.res * 1.02))

    def in_room(name, direction, lens, fill, res, fstop, dim=1.0, drop=0.04):
        # Aiming below the object is what puts a floor in the picture, but fit()
        # centres whatever it is given, so an unchecked drop walks the object
        # straight off the top edge. The frame's own height is the limit.
        for o in show.lights:
            if "base" not in o:
                o["base"] = o.data.energy
            o.data.energy = o["base"] * dim
        room_h = s * fill * res[1] / res[0]
        lim = max(0.0, room_h * 0.47 - s * 0.56)
        if drop > lim:
            print("  %-14s drop %.3f -> %.3f (frame is %.2f m tall)"
                  % (name, drop, lim, room_h), flush=True)
            drop = lim
        target = (0.0, 0.0, -drop)
        pos = fit(direction, lens, s * fill, res, target)
        pos = (pos[0], pos[1], max(pos[2], my_room.FLOOR + 0.20))
        sc.camera = show.camera(name, pos, target, lens=lens, fstop=fstop, focus=(0, 0, 0))
        shoot(name, res=res)

    set_power(emitters, 1.0, halo_lights)
    # the lead picture is the object IN the room, so the frame has to hold the
    # floor and whatever is standing on it, not just the wall behind it
    in_room("staged", (-0.50, -1.0, 0.05), 35, 3.20, ROOM_W, 2.8, drop=0.55)
    in_room("own-room-on", (0.34, -1.0, 0.10), 50, 2.05, ROOM_SQ, 6.3, drop=0.06)
    set_power(emitters, 0.0, halo_lights)
    in_room("own-room-off", (0.34, -1.0, 0.10), 50, 2.05, ROOM_SQ, 6.3, drop=0.06)
    set_power(emitters, 1.0, halo_lights)
    in_room("dark", (-0.42, -1.0, 0.07), 48, 3.00, WIDE, 2.5, dim=0.09, drop=0.40)
    for o in show.lights:
        o.data.energy = o["base"]

    # the loop, in the same room, with the room's own light easing down as the
    # panels come up
    n = args.vframes
    vidcam = None
    for i in range(n):
        t = i / n
        f = (1 - math.cos(2 * math.pi * t)) / 2
        for o in show.lights:
            o.data.energy = o["base"] * (0.30 + 0.70 * (1 - f) ** 1.4)
        set_power(emitters, f ** 1.35, halo_lights)
        if vidcam is None:
            vpos = fit((-0.52, -1.0, 0.16), 44, s * 2.35, (1040, 720), (0.0, 0.0, -0.04))
            vpos = (vpos[0], vpos[1], max(vpos[2], my_room.FLOOR + 0.20))
            vidcam = show.camera("loop", vpos, (0.0, 0.0, -0.04), lens=44, fstop=3.5,
                                 focus=(0, 0, 0))
        sc.camera = vidcam
        shoot(f"vid-{i:02d}", res=(1040, 720))
    for o in show.lights:
        o.data.energy = o["base"]
    set_power(emitters, 1.0, halo_lights)
    for o in show.col.objects:
        o.hide_render = True

    # ------------------------------------------------------------- their room
    room = my_room.Room(offset=(0, 0, 0)).build()
    cam = room.camera("my room", (0.42, -2.55, -0.14), (0.05, 0.0, -0.42), lens=30,
                      fstop=8.0, focus=(0, 0, 0))
    sc.camera = cam
    set_power(emitters, 1.0, halo_lights)
    shoot("my-room-on", res=(1180, 1475))
    set_power(emitters, 0.0, halo_lights)
    shoot("my-room-off", res=(1180, 1475))
    set_power(emitters, 1.0, halo_lights)

    print("DONE", args.id, flush=True)


if __name__ == "__main__":
    main()
