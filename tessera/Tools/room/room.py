# The room, rendered: the mockup's framing, one to one, with a real record
# player on the table: the Tessera TT-900WW, turntable and speakers, a 1:1
# replica (ChatGPT's model, vendored as tt900-white.blend). Outputs, by mode
# (argument after --): base, light, recshade, needle, geom (the still and
# its layers); overhead, overshade, overlight, overgeom (from above); dive,
# divelight (the way in to the record); intro, lightfilm (the film opening);
# mark, marklight (the mark opening). See README.md.
import bpy, bmesh, math, os, sys, json, random
from mathutils import Vector, Matrix
from bpy_extras.object_utils import world_to_camera_view

S = os.path.dirname(os.path.abspath(__file__))
COVER = os.path.join(S, "cover.jpg")
MODE = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "base"
MODES = {"base", "light", "recshade", "needle", "geom", "overhead", "overshade", "overlight", "overgeom",
         "dive", "divelight", "intro", "lightfilm", "mark", "marklight"}
if MODE not in MODES:
    sys.exit(f"room.py: no mode {MODE!r} (the TT-900 has no dust cover, so cover and the badge passes are gone)")
random.seed(7)

bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = 'CYCLES'
sc.cycles.use_denoising = True
try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'; prefs.get_devices()
    for d in prefs.devices: d.use = True
    try: prefs.kernel_optimization_level = 'OFF'
    except Exception: pass
    sc.cycles.device = 'GPU'
except Exception as e:
    print("cpu", e)
sc.render.fps = 30
sc.view_settings.view_transform = 'AgX'
sc.view_settings.exposure = -1.0

def mat(name, color=(0.9, 0.9, 0.9), rough=0.6, metallic=0.0, image=None, emission=None, strength=1.0, alpha=None, ior=None):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metallic
    if alpha is not None:
        b.inputs["Alpha"].default_value = alpha; m.blend_method = 'BLEND'
    if ior is not None: b.inputs["IOR"].default_value = ior
    if image is not None:
        tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = image
        if emission:
            b.inputs["Base Color"].default_value = (0, 0, 0, 1)
            nt.links.new(tex.outputs["Color"], b.inputs["Emission Color"])
            b.inputs["Emission Strength"].default_value = strength
        else:
            nt.links.new(tex.outputs["Color"], b.inputs["Base Color"])
    elif emission:
        b.inputs["Emission Color"].default_value = (*emission, 1)
        b.inputs["Emission Strength"].default_value = strength
    return m

def box(name, size, loc, m, bevel=None, parent=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
    o = bpy.context.active_object; o.name = name
    # scale the mesh itself: transform_apply(scale=True) also bakes the
    # location here, which leaves the object at the origin and breaks any
    # animation of its location
    o.data.transform(Matrix.Diagonal((size[0], size[1], size[2], 1.0)))
    o.data.materials.append(m)
    if bevel:
        bv = o.modifiers.new("bevel", 'BEVEL'); bv.width = bevel; bv.segments = 5
        bpy.ops.object.shade_smooth_by_angle()
    if parent: o.parent = parent
    return o

def cyl(name, r, depth, loc, m, rot=(0, 0, 0), verts=96, parent=None, bevel=None):
    bpy.ops.mesh.primitive_cylinder_add(radius=r, depth=depth, location=loc, rotation=rot, vertices=verts)
    o = bpy.context.active_object; o.name = name; o.data.materials.append(m)
    if bevel:
        bv = o.modifiers.new("bevel", 'BEVEL'); bv.width = bevel; bv.segments = 3
    bpy.ops.object.shade_smooth_by_angle()
    if parent: o.parent = parent
    return o

white = mat("white", (0.92, 0.91, 0.89), 0.75)
floor_m = mat("floor", (0.86, 0.85, 0.82), 0.7)
table_m = mat("table", (0.95, 0.94, 0.92), 0.5)
lacquer = mat("lacquer", (0.96, 0.96, 0.95), 0.18)
alu = mat("aluminium", (0.78, 0.78, 0.76), 0.25, 1.0)
felt = mat("felt", (0.11, 0.11, 0.12), 0.95)
vinyl = mat("vinyl", (0.02, 0.02, 0.02), 0.42)
chrome = mat("chrome", (0.85, 0.85, 0.85), 0.18, 1.0)
black = mat("black", (0.03, 0.03, 0.03), 0.5)
rubber = mat("rubber", (0.03, 0.03, 0.03), 0.9)
frame_m = mat("frame", (0.32, 0.32, 0.32), 0.55)
acrylic = mat("acrylic", (0.88, 0.94, 1.0), 0.06, alpha=0.12, ior=1.49)
amber = mat("amber", (0.2, 0.15, 0.06), 0.4, emission=(0.93, 0.62, 0.18), strength=0.0)
amber_soft = mat("amber_soft", (0.16, 0.12, 0.05), 0.4, emission=(0.93, 0.62, 0.18), strength=0.0)
plate_m = mat("plate", (0.82, 0.80, 0.76), 0.3, emission=(1.0, 0.98, 0.94), strength=0.0)
plate_mid = mat("plate_mid", (0.86, 0.84, 0.80), 0.3, emission=(1.0, 0.98, 0.94), strength=0.0)
# for the app to tint: the plates in white, the middle one lit; the record as
# matte white so its shading can be multiplied under any pressing
plate_white = mat("plate_white", (0.92, 0.92, 0.92), 0.25, emission=(1, 1, 1), strength=0.6)
plate_white_lit = mat("plate_white_lit", (1, 1, 1), 0.25, emission=(1, 1, 1), strength=2.2)
matte_white = mat("matte_white", (0.86, 0.86, 0.86), 0.9)
cover = bpy.data.images.load(COVER)
label_m = mat("label", (0.93, 0.91, 0.86), 0.7)      # paper: the app lays the sleeve on it
face_dark = mat("face_dark", (0.012, 0.012, 0.012), 0.45)

def grooves():
    T = 1024; img = bpy.data.images.new("grooves", T, T); buf = [0.0] * (T * T * 4)
    for y in range(T):
        for x in range(T):
            d = math.hypot(x - T / 2, y - T / 2) / (T / 2)
            v = 0.30 if (int(d * 900) % 2 == 0) else 0.42
            if d < 0.35: v = 0.5
            o = (y * T + x) * 4; buf[o] = buf[o + 1] = buf[o + 2] = v; buf[o + 3] = 1
    img.pixels = buf
    tex = vinyl.node_tree.nodes.new("ShaderNodeTexImage"); tex.image = img
    vinyl.node_tree.links.new(tex.outputs["Color"], vinyl.node_tree.nodes["Principled BSDF"].inputs["Roughness"])
grooves()

back = box("back", (6, 0.02, 3.2), (0, 0.01, 1.6), white)
box("floor", (6, 6, 0.02), (0, -3, -0.01), floor_m)
box("left", (0.02, 6, 3.2), (-2.2, -3, 1.6), white)
box("right", (0.02, 6, 3.2), (2.2, -3, 1.6), white)
box("ceiling", (6, 6, 0.02), (0, -3, 2.9), white)

tz = 0.76
box("top", (1.5, 0.62, 0.035), (0, -0.33, tz - 0.0175), table_m, bevel=0.004)
box("console", (1.5, 0.60, tz - 0.035), (0, -0.32, (tz - 0.035) / 2), table_m)

px, py = 0.0, -0.33
top = tz

# The deck: the Tessera TT-900WW, turntable and both speakers at 1:1, appended
# from tt900-white.blend and stood on the table. The model is in metres, the
# turntable's footprint centred on its root, the feet on z = 0.
TT900 = os.path.join(S, "tt900-white.blend")
with bpy.data.libraries.load(TT900, link=False) as (src, dst):
    dst.collections = [c for c in src.collections if c == "Tessera TT-900WW"]
deck_coll = dst.collections[0]
sc.collection.children.link(deck_coll)
deck_root = bpy.data.objects["Tessera_TT_900WW"]
deck_root.location = (px, py, top)
bpy.context.view_layer.update()
MM = 0.001
def deck(name):
    return bpy.data.objects["WW | " + name]
def deck_point(x, y, z):
    """A point given in the model's own millimetres, placed in the room."""
    return Vector((px + x * MM, py + y * MM, top + z * MM))
# the names the passes below ask for
for old, new in (("Turntable | straight-edge lacquer plinth", "plinth"), ("Platter | ABS rim", "platter"),
                 ("Slipmat | felt", "slipmat"), ("Center spindle", "spindle"),
                 ("Tonearm rest post", "armrest"), ("Tonearm rest clip", "cradle")):
    deck(old).name = new

# the record on the mat: a twelve inch, a little over the 280 mm platter
pc = (px - 43 * MM, py + 4 * MM)
MAT_TOP = top + 0.0570                      # the felt's face; the mat's print sits 0.03 mm over it
# 270 mm rather than a twelve inch: it sits inside the 280 mm platter and never
# hangs off the deck; the label and the groove scale with it
REC_R = 0.135
LABEL_R = REC_R * 0.0505 / 0.150
rec = cyl("record", REC_R, 0.0022, (pc[0], pc[1], MAT_TOP + 0.00005 + 0.0011), vinyl, verts=200)
REC_TOP = MAT_TOP + 0.00005 + 0.0022
lab = cyl("label", LABEL_R, 0.0008, (0, 0, 0.0015), label_m, verts=96); lab.parent = rec

# The arm. The model is built parked in its rest, so the rest is no turn at
# all; the turret's hex housing and bearing turn with the arm, and the arm
# proper also tilts about the bearing, which is how it lifts. Both groups are
# re-parented about the pivot with an identity parent inverse, so a pose is
# one matrix each.
ARM_TILTS = ["Tonearm straight shaft", "Tonearm upper sleeve", "Tonearm counterweight axle", "Tonearm rear weight",
             "Tonearm weight end face", "Headshell", "Headshell finger lift", "Ceramic cartridge",
             "Red stylus carrier", "Stylus cantilever"] + sorted(
    o.name[5:] for o in deck_coll.objects if o.name.startswith("WW | Headshell recessed screw"))
ARM_TURNS = ["Tonearm upper hex housing", "Tonearm yaw bearing"]
piv = tuple(deck_point(145, 101, 77))         # the turret's axis, at the bearing
tip = tuple(deck_point(132.8, -104.0, 56.8))  # the stylus, parked
TIP_REST_Z = tip[2]
STYLUS_R = 0.00022          # the cantilever's radius: its underside, not its axis, meets the vinyl
dx, dy, dz = tip[0] - piv[0], tip[1] - piv[1], tip[2] - piv[2]
ARM_DX, ARM_DY = dx, dy
REST = 0.0
armpivot = bpy.data.objects.new("armpivot", None); sc.collection.objects.link(armpivot)
armturn = bpy.data.objects.new("armturn", None); sc.collection.objects.link(armturn)
def rig(names, holder):
    parts = []
    for n in names:
        o = deck(n)
        mw = o.matrix_world.copy()
        o.parent = holder; o.matrix_parent_inverse = Matrix.Identity(4)
        o.matrix_basis = Matrix.Translation(-Vector(piv)) @ mw
        parts.append(o)
    return parts
arm_parts = rig(ARM_TILTS, armpivot) + rig(ARM_TURNS, armturn)
# the rest's hook is closed over the arm in the model; open it to a cradle,
# so the arm lifts straight out of it instead of through its top
cr = bpy.data.objects["cradle"]
bm = bmesh.new(); bm.from_mesh(cr.data)
bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.z > 0.0715], context='VERTS')
bm.to_mesh(cr.data); bm.free(); cr.data.update()

ARM_ACROSS = Vector((ARM_DY, -ARM_DX, 0)).normalized()     # across the arm, level
TIP_LOCAL = Vector(tip) - Vector(piv)
def tilt_for(height):
    """The tilt about the bearing that puts the stylus at this height."""
    want = height - piv[2]
    f = lambda t: (Matrix.Rotation(t, 4, ARM_ACROSS) @ TIP_LOCAL).z
    lo, hi = -0.35, 0.35
    rising = f(hi) > f(lo)
    for _ in range(60):
        m = (lo + hi) / 2
        if (f(m) < want) == rising: lo = m
        else: hi = m
    return (lo + hi) / 2
def arm_pose(angle, height=None):
    """The arm turned by angle about the turret (negative swings it in over
    the record) with the stylus at height; parked in its cradle by default."""
    h = TIP_REST_Z if height is None else height
    turn = Matrix.Translation(Vector(piv)) @ Matrix.Rotation(angle, 4, 'Z')
    armturn.matrix_world = turn
    armpivot.matrix_world = turn @ Matrix.Rotation(tilt_for(h), 4, ARM_ACROSS)
# the swing that brings the stylus nearest the spindle: the needle's search
# stays on the near side of it, where the radius falls as the arm swings in
A_MIN = math.atan2(pc[1] - piv[1], pc[0] - piv[0]) - math.atan2(ARM_DY, ARM_DX)
while A_MIN > 0: A_MIN -= 2 * math.pi
while A_MIN <= -2 * math.pi: A_MIN += 2 * math.pi
arm_pose(REST)

side = 0.56; cz = 1.54                   # high enough that the opened cover stays under it
N = 64; T = 512; cell = T // N
w, h = cover.size; pix = list(cover.pixels)
def sample(u, v):
    x = min(w - 1, int(u * w)); y = min(h - 1, int(v * h)); o = (y * w + x) * 4
    return pix[o], pix[o + 1], pix[o + 2]
led = bpy.data.images.new("led", T, T); buf = [0.0] * (T * T * 4)
for gy in range(N):
    for gx in range(N):
        r, g, b = sample((gx + 0.5) / N, (gy + 0.5) / N)
        cx, cy = gx * cell + cell / 2, gy * cell + cell / 2
        for yy in range(gy * cell, gy * cell + cell):
            for xx in range(gx * cell, gx * cell + cell):
                d = math.hypot(xx + 0.5 - cx, yy + 0.5 - cy); k = 1.0 if d < cell * 0.36 else (0.35 if d < cell * 0.36 + 0.9 else 0.0)
                o = (yy * T + xx) * 4; buf[o], buf[o + 1], buf[o + 2], buf[o + 3] = r * k, g * k, b * k, 1.0
led.pixels = buf
led_m = mat("led", image=led, emission=True, strength=16.0)
white_led = mat("led_white", (0, 0, 0), emission=(1, 1, 1), strength=10.0)
box("wallframe", (side + 0.056, 0.03, side + 0.056), (0, -0.015, cz), frame_m)
bpy.ops.mesh.primitive_plane_add(size=side, location=(0, -0.031, cz), rotation=(math.pi / 2, 0, 0))
face = bpy.context.active_object; face.name = "ledface"; face.data.materials.append(led_m)

# the TT-900 has no dust cover; its Tessera prints are part of the model
plates = []
def hide_cover():
    pass

def area(loc, rot, energy, size):
    bpy.ops.object.light_add(type='AREA', location=loc)
    l = bpy.context.active_object; l.data.energy = energy; l.data.size = size; l.rotation_euler = rot; return l
L1 = area((-1.2, -2.6, 2.6), (math.radians(35), math.radians(-15), math.radians(-25)), 18, 2.0)
L2 = area((1.6, -2.2, 2.4), (math.radians(35), math.radians(25), math.radians(35)), 9, 2.5)
bpy.ops.object.light_add(type='SPOT', location=(0.30, 0.05, 2.62))
SPOT = bpy.context.active_object; SPOT.data.energy = 520; SPOT.data.spot_size = math.radians(24); SPOT.data.spot_blend = 0.55
SPOT.data.color = (1.0, 0.95, 0.86); SPOT.data.shadow_soft_size = 0.18
sc.world = bpy.data.worlds.new("w"); sc.world.use_nodes = True
wbg = sc.world.node_tree.nodes["Background"]
wbg.inputs[0].default_value = (0.9, 0.9, 0.9, 1); wbg.inputs[1].default_value = 0.05

bpy.ops.object.camera_add(location=(0.0, -2.05, 1.22))
cam = bpy.context.active_object; cam.data.lens = 30; cam.data.sensor_fit = 'VERTICAL'; cam.data.sensor_height = 36
def aim(obj, target, frame=None):
    d = Vector(target) - obj.location
    obj.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()
    if frame is not None:
        obj.keyframe_insert("location", frame=frame); obj.keyframe_insert("rotation_euler", frame=frame)
SEAT = ((0.0, -2.05, 1.22), (0.0, 0.0, 1.12))
CLOSE = ((0.30, -0.98, 1.40), (-0.08, -0.20, 1.20))
sc.camera = cam
aim(SPOT, (pc[0], pc[1], top + 0.06))
def ndc(p):
    v = world_to_camera_view(sc, cam, Vector(p)); return (v.x, 1 - v.y)
def face_quad():
    return [ndc((sx * side / 2, -0.031, cz + sz * side / 2)) for sx, sz in ((-1, 1), (1, 1), (1, -1), (-1, -1))]
def label_ellipse():
    m = lab.matrix_world; c = m @ Vector((0, 0, 0)); ax = m @ Vector((LABEL_R, 0, 0)); ay = m @ Vector((0, LABEL_R, 0))
    c2, a2, b2 = ndc(c), ndc(ax), ndc(ay); return [c2[0], c2[1], a2[0] - c2[0], a2[1] - c2[1], b2[0] - c2[0], b2[1] - c2[1]]
def record_quad():
    # the square the record sits in, on its own plane: the app draws the
    # pressing through it, so the disc lands on the platter in perspective
    m = rec.matrix_world; z = 0.0011
    return [ndc(m @ Vector((sx * REC_R, sy * REC_R, z))) for sx, sy in ((-1, 1), (1, 1), (1, -1), (-1, -1))]
def badge_quads():
    return []

def fcurves(obj):
    try: return list(obj.animation_data.action.fcurves)
    except AttributeError:
        out = []; act = obj.animation_data.action
        for layer in act.layers:
            for strip in layer.strips:
                for slot in act.slots:
                    try: out += list(strip.channelbag(slot).fcurves)
                    except Exception: pass
        return out
def ease_all(obj, kind='BEZIER'):
    for fc in fcurves(obj):
        for kp in fc.keyframe_points:
            kp.interpolation = kind
            if kind == 'BEZIER': kp.easing = 'EASE_IN_OUT'

def set_final():
    cam.location = SEAT[0]; aim(cam, SEAT[1])
    arm_pose(REST)
    bpy.context.view_layer.update()

if MODE in ("base", "light", "geom", "needle", "cover", "badge", "recshade"):
    set_final()
PROBE = bool(os.environ.get("PROBE"))

# The needle's places. The stylus sits at a radius from the spindle; the
# groove carries it from the lead-in (146 mm on a twelve inch) to the run-
# out (64 mm), linearly in time, so a song's progress is a radius, and a
# radius is an angle of the arm. Index 0 is the arm on its cradle, 1 to
# LEAD-1 the swing in (arm up), LEAD onward the groove positions.
LEAD, TRACK, LIFTS = 10, 32, 5
UP = 0.010
R_IN, R_OUT = REC_R * 0.146 / 0.150, REC_R * 0.064 / 0.150
def stylus_radius(angle):
    c, s_ = math.cos(angle), math.sin(angle)
    x = piv[0] + ARM_DX * c - ARM_DY * s_; y = piv[1] + ARM_DX * s_ + ARM_DY * c
    return math.hypot(x - pc[0], y - pc[1])
def angle_for(radius):
    lo, hi = A_MIN, REST                     # radius grows with the angle
    for _ in range(48):
        m = (lo + hi) / 2
        if stylus_radius(m) < radius: lo = m
        else: hi = m
    return (lo + hi) / 2
A_IN, A_OUT = angle_for(R_IN), angle_for(R_OUT)
def needle_angle(i):
    if i < LEAD: return REST + (A_IN - REST) * (i / (LEAD - 1))
    return angle_for(R_IN + (R_OUT - R_IN) * ((i - LEAD) / (TRACK - 1)))
def needle_height(i, l):
    """Where the stylus is for a render: on the cradle it rises from where
    it lies to the full lift; everywhere else it is on the record's face,
    lifted by a fraction of UP."""
    k = l / (LIFTS - 1)
    if i == 0: return TIP_REST_Z + (REC_TOP + STYLUS_R + UP - TIP_REST_Z) * k
    return REC_TOP + STYLUS_R + UP * k
def pose_needle(i, l):
    arm_pose(needle_angle(i), needle_height(i, l))
def needle_poses():
    out = []
    for l in range(LIFTS): out.append((0, l))
    for i in range(1, LEAD): out.append((i, LIFTS - 1))
    for i in range(LEAD, LEAD + TRACK):
        for l in range(LIFTS): out.append((i, l))
    return out
def needle_border():
    pts = []
    for i, l in ((0, 0), (0, LIFTS - 1), (LEAD, 0), (LEAD, LIFTS - 1), (LEAD + TRACK - 1, 0), (LEAD + TRACK - 1, LIFTS - 1), (LEAD // 2, LIFTS - 1)):
        pose_needle(i, l); bpy.context.view_layer.update()
        for o in arm_parts:
            pts += [world_to_camera_view(sc, cam, o.matrix_world @ v.co) for v in o.data.vertices]
    pad = 0.02                               # room for the shadow, more below it
    x0, x1 = min(p.x for p in pts), max(p.x for p in pts); y0, y1 = min(p.y for p in pts), max(p.y for p in pts)
    return (max(0, x0 - pad), max(0, y0 - pad * 1.6), min(1, x1 + pad), min(1, y1 + pad))

if MODE == "needle":
    for o in bpy.data.objects:
        if o.type == 'MESH' and o not in arm_parts: o.hide_render = True
    hide_cover()
    # what the arm's shadow falls on stays, as a catcher: only the shadow shows
    for name in ("record", "label", "slipmat", "platter", "plinth", "top", "cradle", "armrest", "spindle", "WW | Platter upper edge", "WW | Tonearm rotating pedestal", "WW | Tonearm hex mounting plinth", "WW | Tonearm base groove", "WW | Cue platform", "WW | Cue platform support"):
        o = bpy.data.objects.get(name)
        if o: o.hide_render = False; o.is_shadow_catcher = True
    sc.render.film_transparent = True
    sc.render.resolution_x, sc.render.resolution_y = 1170, 2532
    bx0, by0, bx1, by1 = needle_border()
    sc.render.use_border = True; sc.render.use_crop_to_border = True
    sc.render.border_min_x, sc.render.border_max_x = bx0, bx1
    sc.render.border_min_y, sc.render.border_max_y = by0, by1
    json.dump({"needle": [bx0, 1 - by1, bx1, 1 - by0], "lead": LEAD, "track": TRACK, "lifts": LIFTS},
              open(os.path.join(S, "room-needle.json"), "w"))
    print("NEEDLE angles", math.degrees(A_IN), math.degrees(A_OUT), "border", bx0, by0, bx1, by1)
    sc.cycles.samples = 64
    os.makedirs(os.path.join(S, "room-needle"), exist_ok=True)
    for i, l in needle_poses():
        f = os.path.join(S, "room-needle", "needle-%02d-%d.png" % (i, l))
        if os.path.exists(f): continue
        pose_needle(i, l); bpy.context.view_layer.update()
        sc.render.filepath = f; bpy.ops.render.render(write_still=True)

if MODE == "base":
    for o in arm_parts: o.hide_render = True
    hide_cover(); face.data.materials[0] = face_dark
    back.is_shadow_catcher = True; sc.render.film_transparent = True
    sc.cycles.samples = 16 if PROBE else 200
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (1170, 2532)
    sc.render.filepath = os.path.join(S, "room-base.png"); bpy.ops.render.render(write_still=True)

if MODE == "light":
    face.visible_camera = False; back.visible_camera = False
    for o in arm_parts: o.hide_render = True
    hide_cover()
    for o in bpy.data.objects:
        if o.type == 'LIGHT': o.hide_render = True
    wbg.inputs[1].default_value = 0.0
    face.data.materials[0] = white_led
    sc.cycles.samples = 16 if PROBE else 160
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (1170, 2532)
    sc.render.filepath = os.path.join(S, "room-light.png"); bpy.ops.render.render(write_still=True)

if MODE == "recshade":
    # the record and its label in matte white, lit by the room, with the
    # platter and plinth as catchers: what the pressing is multiplied by
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.name not in ("record", "label"): o.hide_render = True
    for name in ("platter", "slipmat", "plinth", "spindle"):
        o = bpy.data.objects.get(name)
        if o: o.hide_render = False; o.is_shadow_catcher = True
    for o in arm_parts: o.hide_render = True
    hide_cover()
    rec.data.materials[0] = matte_white; lab.data.materials[0] = matte_white
    face.data.materials[0] = face_dark
    sc.render.film_transparent = True
    sc.render.resolution_x, sc.render.resolution_y = 1170, 2532
    rn = [world_to_camera_view(sc, cam, rec.matrix_world @ v.co) for v in rec.data.vertices]
    pad = 0.006
    bx0, bx1 = max(0, min(q.x for q in rn) - pad), min(1, max(q.x for q in rn) + pad)
    by0, by1 = max(0, min(q.y for q in rn) - pad), min(1, max(q.y for q in rn) + pad)
    sc.render.use_border = True; sc.render.use_crop_to_border = True
    sc.render.border_min_x, sc.render.border_max_x = bx0, bx1
    sc.render.border_min_y, sc.render.border_max_y = by0, by1
    json.dump({"record_box": [bx0, 1 - by1, bx1, 1 - by0]}, open(os.path.join(S, "room-recshade.json"), "w"))
    sc.cycles.samples = 16 if PROBE else 160
    sc.render.filepath = os.path.join(S, "room-recshade.png"); bpy.ops.render.render(write_still=True)


# In close on the record: the deck from straight above, the cover stood
# open, the arm home, framed so the record spans most of the width and
# sits in the upper part, the pressing panel under it. The dive is the way
# there from the seat: the camera rises and tilts down over the deck as the
# cover swings up; played backwards, it is the way out.
OVER_H, OVER_DY = 0.694, 0.167
OVER = (pc[0], pc[1] - OVER_DY, REC_TOP - 0.001 + OVER_H)
DIVE_N = 36
def add_floor():
    # the seat never sees the floor, so the room has none; from above, and
    # on the way there, the table's front edge would open onto nothing
    floor_m = mat("floor", (0.02, 0.018, 0.016), 0.9)
    return box("floor", (8, 8, 0.02), (0, -2.0, -0.01), floor_m)
def face_visible():
    pts = [world_to_camera_view(sc, cam, face.matrix_world @ v.co) for v in face.data.vertices]
    return all(p.z > 0.05 for p in pts) and any(-0.2 < p.x < 1.2 and -0.2 < p.y < 1.2 for p in pts)
def set_over():
    cam.location = OVER; cam.rotation_euler = (0, 0, 0)
    arm_pose(REST)
    bpy.context.view_layer.update()
def dive_path():
    cam.location = SEAT[0]; aim(cam, SEAT[1], frame=1)
    cam.location = OVER; cam.rotation_euler = (0, 0, 0)
    cam.keyframe_insert("location", frame=DIVE_N); cam.keyframe_insert("rotation_euler", frame=DIVE_N)
    ease_all(cam)
    arm_pose(REST)
    sc.frame_start, sc.frame_end = 1, DIVE_N
    sc.frame_set(1); bpy.context.view_layer.update()

if MODE in ("overhead", "overshade", "overlight", "overgeom"):
    set_over()
    if MODE in ("overhead", "overlight"): add_floor()
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (1170, 2532)
    for o in arm_parts: o.hide_render = False
    if MODE == "overhead":
        # the still: lit as the room is, the wall dark, the record and label
        # holes for the pressing, the plates left out (edge-on from here)
        for pl, h in plates: pl.hide_render = True
        face.data.materials[0] = face_dark; face.is_holdout = True
        rec.is_holdout = True; lab.is_holdout = True
        back.is_shadow_catcher = True; sc.render.film_transparent = True
        sc.cycles.samples = 16 if PROBE else 200
        sc.render.filepath = os.path.join(S, "room-overhead.png"); bpy.ops.render.render(write_still=True)
    if MODE == "overshade":
        for o in bpy.data.objects:
            if o.type == 'MESH' and o.name not in ("record", "label"): o.hide_render = True
        for name in ("platter", "slipmat", "plinth", "spindle"):
            o = bpy.data.objects.get(name)
            if o: o.hide_render = False; o.is_shadow_catcher = True
        for pl, h in plates: pl.hide_render = True
        rec.data.materials[0] = matte_white; lab.data.materials[0] = matte_white
        face.data.materials[0] = face_dark
        sc.render.film_transparent = True
        rn = [world_to_camera_view(sc, cam, rec.matrix_world @ v.co) for v in rec.data.vertices]
        pad = 0.006
        bx0, bx1 = max(0, min(q.x for q in rn) - pad), min(1, max(q.x for q in rn) + pad)
        by0, by1 = max(0, min(q.y for q in rn) - pad), min(1, max(q.y for q in rn) + pad)
        sc.render.use_border = True; sc.render.use_crop_to_border = True
        sc.render.border_min_x, sc.render.border_max_x = bx0, bx1
        sc.render.border_min_y, sc.render.border_max_y = by0, by1
        json.dump({"over_record_box": [bx0, 1 - by1, bx1, 1 - by0]}, open(os.path.join(S, "room-overshade.json"), "w"))
        sc.cycles.samples = 16 if PROBE else 160
        sc.render.filepath = os.path.join(S, "room-overshade.png"); bpy.ops.render.render(write_still=True)
    if MODE == "overlight":
        for o in bpy.data.objects:
            if o.type == 'LIGHT': o.hide_render = True
        face.visible_camera = False; back.visible_camera = False
        for pl, h in plates: pl.hide_render = True
        wbg.inputs[1].default_value = 0.0
        face.data.materials[0] = white_led
        sc.render.film_transparent = False
        sc.cycles.samples = 16 if PROBE else 160
        sc.render.filepath = os.path.join(S, "room-overlight.png"); bpy.ops.render.render(write_still=True)
    if MODE == "overgeom":
        rn = [ndc(rec.matrix_world @ v.co) for v in rec.data.vertices]
        geom = {"over_record_quad": record_quad(), "over_label": label_ellipse(),
                "over_record": [min(p[0] for p in rn), min(p[1] for p in rn), max(p[0] for p in rn), max(p[1] for p in rn)]}
        json.dump(geom, open(os.path.join(S, "room-overgeom.json"), "w")); print("OVERGEOM", json.dumps(geom))

if MODE in ("dive", "divelight"):
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (780, 1688)
    if MODE in ("dive", "divelight"): add_floor()
    dive_path()
    if MODE == "dive":
        face.data.materials[0] = face_dark; face.is_holdout = True
        rec.is_holdout = True; lab.is_holdout = True
        for pl, h in plates: pl.hide_render = True
        back.is_shadow_catcher = True
        sc.render.film_transparent = True
        sc.cycles.samples = 16 if PROBE else 48
        track = []
        for f in range(1, DIVE_N + 1):
            sc.frame_set(f); bpy.context.view_layer.update()
            # the wall leaves the frame as the camera tilts down: no quad then,
            # or its corners behind the camera would land anywhere on screen
            track.append({"face": face_quad() if face_visible() else None, "label": label_ellipse(), "badge": badge_quads(), "record": record_quad()})
        json.dump({"fps": 30, "frames": track}, open(os.path.join(S, "room-dive-track.json"), "w"))
        prefix = "dive_"
    if MODE == "divelight":
        for o in bpy.data.objects:
            if o.type == 'LIGHT': o.hide_render = True
        face.visible_camera = False; back.visible_camera = False
        for pl, h in plates: pl.hide_render = True
        wbg.inputs[1].default_value = 0.0
        face.data.materials[0] = white_led
        sc.render.film_transparent = False
        sc.cycles.samples = 16 if PROBE else 32
        prefix = "light_"
    if os.environ.get("DIVE_PROBE"):
        for f in [int(x) for x in os.environ["DIVE_PROBE"].split(",")]:
            sc.frame_set(f); bpy.context.view_layer.update()
            sc.render.filepath = os.path.join(S, "dive-probe-%s%d.png" % (prefix, f)); bpy.ops.render.render(write_still=True)
    else:
        os.makedirs(os.path.join(S, "room-" + MODE), exist_ok=True)
        sc.render.filepath = os.path.join(S, "room-" + MODE, prefix); bpy.ops.render.render(animation=True)


# The second opening, in the room itself: nine plates of the mark fly in
# through the dark room and settle in front of the wall, glow, then grow
# into the panel's nine cells and hand over to the live wall; meanwhile the
# table and the deck build up out of coarse blocks that refine into the
# real geometry as the lights come up. The camera never leaves the seat, so
# the last frame is the still.
MARK_N = 96
if MODE in ("mark", "marklight"):
    set_final()
    random.seed(11)
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (780, 1688)
    sc.frame_start, sc.frame_end = 1, MARK_N
    FC = Vector((0, -0.031, cz)); FRONT = Vector((0, -0.024, 0))
    ps, pp, cell = side * 0.16, side * 0.22, side / 3
    def fade_alpha(m, f_on, f_off):
        a = m.node_tree.nodes["Principled BSDF"].inputs["Alpha"]
        a.default_value = 1.0; a.keyframe_insert("default_value", frame=f_on)
        a.default_value = 0.0; a.keyframe_insert("default_value", frame=f_off)
    mark_white = mat("mark_white", (0.92, 0.92, 0.92), 0.25, emission=(1, 1, 1), strength=0.6, alpha=1.0)
    mark_white_lit = mat("mark_white_lit", (1, 1, 1), 0.25, emission=(1, 1, 1), strength=2.2, alpha=1.0)
    mark_glow = mat("mark_glow", (0, 0, 0), emission=(1, 1, 1), strength=3.0, alpha=1.0)
    for m in (mark_white, mark_white_lit, mark_glow): fade_alpha(m, 84, 95)
    marks = []
    for i in range(9):
        gx, gy = i % 3 - 1, 1 - i // 3
        home = FC + FRONT + Vector((gx * pp, 0, gy * pp))
        grown = FC + FRONT + Vector((gx * cell, 0, gy * cell))
        m = box(f"mark{i}", (ps, 0.012, ps), tuple(home), mark_white_lit if i == 4 else mark_white, bevel=0.002)
        away = home + Vector((random.uniform(-0.9, 0.9), random.uniform(-1.6, -0.5), random.uniform(-0.8, 0.7)))
        f0 = 4 + i * 3
        m.location = away; m.scale = (0.05, 0.05, 0.05)
        m.rotation_euler = (random.uniform(-2.5, 2.5), random.uniform(-2.5, 2.5), random.uniform(-2.5, 2.5))
        for k in ("location", "scale", "rotation_euler"): m.keyframe_insert(k, frame=f0)
        m.location = home; m.scale = (1, 1, 1); m.rotation_euler = (0, 0, 0)
        for k in ("location", "scale", "rotation_euler"): m.keyframe_insert(k, frame=f0 + 28)
        for k in ("location", "scale"): m.keyframe_insert(k, frame=56)
        m.location = grown; m.scale = (cell / ps * 0.985, 1, cell / ps * 0.985)
        for k in ("location", "scale"): m.keyframe_insert(k, frame=84)
        ease_all(m)
        marks.append(m)
    # the wall's frame grows out with the mark
    wf = bpy.data.objects["wallframe"]
    wf.hide_render = True; wf.keyframe_insert("hide_render", frame=1)
    wf.hide_render = False; wf.keyframe_insert("hide_render", frame=56)
    wf.scale = (0.6, 1, 0.6); wf.keyframe_insert("scale", frame=56)
    wf.scale = (1, 1, 1); wf.keyframe_insert("scale", frame=84)
    ease_all(wf)
    # the table and the deck: out of blocks, coarse to fine, then themselves
    keep_out = {face.name, back.name, wf.name, "ceiling", "left", "right"} | {m.name for m in marks} | {p.name for p, h in plates}
    build = [o for o in bpy.data.objects if o.type == 'MESH' and o.name not in keep_out and not o.name.startswith("floor")]
    for j, o in enumerate(build):
        rm = o.modifiers.new("blocks", 'REMESH'); rm.mode = 'BLOCKS'; rm.use_remove_disconnected = False
        for f, d in ((1, 3), (66, 4), (74, 5), (82, 6), (88, 7)):
            rm.octree_depth = d; rm.keyframe_insert("octree_depth", frame=f)
        rm.show_render = True; rm.keyframe_insert("show_render", frame=91)
        rm.show_render = False; rm.keyframe_insert("show_render", frame=92)
        bd = o.modifiers.new("build", 'BUILD'); bd.frame_start = 48 + (j * 7) % 9; bd.frame_duration = 22
        bd.use_random_order = True; bd.seed = j
        ease_all(o, kind='CONSTANT')
    for p, h in plates:
        p.hide_render = True; p.keyframe_insert("hide_render", frame=1)
        p.hide_render = False; p.keyframe_insert("hide_render", frame=74)
    # the lights come up with the deck
    for l in (L1, L2, SPOT):
        e = l.data.energy
        l.data.energy = 0.0; l.data.keyframe_insert("energy", frame=44)
        l.data.energy = e; l.data.keyframe_insert("energy", frame=76)
    sc.render.film_transparent = True
    if MODE == "mark":
        for m in marks: m.hide_render = True
        for p, h in plates: p.hide_render = True; p.animation_data_clear()
        # the face is dark until the plates cover it, then a hole for the live wall
        face_mark = bpy.data.materials.new("face_mark"); face_mark.use_nodes = True
        nt = face_mark.node_tree; b = nt.nodes["Principled BSDF"]
        b.inputs["Base Color"].default_value = (0.012, 0.012, 0.012, 1); b.inputs["Roughness"].default_value = 0.45
        outn = nt.nodes["Material Output"]; hold = nt.nodes.new("ShaderNodeHoldout"); mix = nt.nodes.new("ShaderNodeMixShader")
        nt.links.new(b.outputs["BSDF"], mix.inputs[1]); nt.links.new(hold.outputs["Holdout"], mix.inputs[2])
        nt.links.new(mix.outputs["Shader"], outn.inputs["Surface"])
        mix.inputs["Fac"].default_value = 0.0; mix.inputs["Fac"].keyframe_insert("default_value", frame=78)
        mix.inputs["Fac"].default_value = 1.0; mix.inputs["Fac"].keyframe_insert("default_value", frame=83)
        face.data.materials[0] = face_mark; face.is_holdout = False
        rec.is_holdout = True; lab.is_holdout = True
        back.is_shadow_catcher = True
        sc.cycles.samples = 16 if PROBE else 48
        track = []
        for f in range(1, MARK_N + 1):
            sc.frame_set(f); bpy.context.view_layer.update()
            cells = max(0.0, (MARK_N - f) / float(MARK_N - 78)) / 3.0 if f >= 78 else None
            track.append({"face": face_quad() if f >= 78 else None, "label": label_ellipse(), "badge": [],
                          "record": record_quad() if f >= 50 else None, "cells": cells})
        json.dump({"fps": 30, "frames": track}, open(os.path.join(S, "room-mark-track.json"), "w"))
        prefix = "mark_"
    if MODE == "marklight":
        for o in bpy.data.objects:
            if o.type == 'LIGHT': o.hide_render = True
        for p, h in plates: p.hide_render = True; p.animation_data_clear()
        for m in marks: m.data.materials[0] = mark_glow
        wbg.inputs[1].default_value = 0.0
        face.data.materials[0] = white_led; face.visible_camera = False; back.visible_camera = False
        st = white_led.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
        st.default_value = 0.0; st.keyframe_insert("default_value", frame=70)
        st.default_value = 2.5; st.keyframe_insert("default_value", frame=92)
        sc.render.film_transparent = False
        sc.cycles.samples = 16 if PROBE else 32
        prefix = "light_"
    if os.environ.get("MARK_PROBE"):
        for f in [int(x) for x in os.environ["MARK_PROBE"].split(",")]:
            sc.frame_set(f); bpy.context.view_layer.update()
            sc.render.filepath = os.path.join(S, "mark-probe-%s%02d.png" % (prefix, f)); bpy.ops.render.render(write_still=True)
    else:
        os.makedirs(os.path.join(S, "room-" + MODE), exist_ok=True)
        sc.render.filepath = os.path.join(S, "room-" + MODE, prefix); bpy.ops.render.render(animation=True)

# The film opening's camera: close over the turntable's front left, on the
# Tessera print on the plinth, drifting in; then back to the seat.
LOGO = deck_point(-151, -124, 41)
def opening_camera():
    cam.location = LOGO + Vector((0.12, -0.40, 0.28)); aim(cam, LOGO + Vector((0.015, 0.015, 0)), frame=1)
    cam.location = LOGO + Vector((0.05, -0.27, 0.19)); aim(cam, LOGO, frame=62)
    cam.location = SEAT[0]; aim(cam, SEAT[1], frame=108)
    ease_all(cam)

if MODE == "lightfilm":
    face.visible_camera = False; back.visible_camera = False
    # the opening's light pass: the room lit by a white wall alone, nothing
    # else, black elsewhere; the app tints it with the sleeve and screens it
    arm_pose(REST)
    for o in bpy.data.objects:
        if o.type == 'LIGHT': o.hide_render = True
    wbg.inputs[1].default_value = 0.0
    face.data.materials[0] = white_led
    sc.render.film_transparent = False
    sc.cycles.samples = 32
    sc.render.resolution_x, sc.render.resolution_y = 780, 1688
    opening_camera()
    sc.frame_start, sc.frame_end = 1, 108
    os.makedirs(os.path.join(S, "room-lightfilm"), exist_ok=True)
    sc.render.filepath = os.path.join(S, "room-lightfilm", "light_"); bpy.ops.render.render(animation=True)

if MODE == "geom":
    sc.render.resolution_x, sc.render.resolution_y = 1170, 2532
    corners = face_quad()
    rn = [ndc(rec.matrix_world @ v.co) for v in rec.data.vertices]
    rx = [p[0] for p in rn]; ry = [p[1] for p in rn]
    bx0, by0, bx1, by1 = needle_border()
    geom = {"face": corners, "record": [min(rx), min(ry), max(rx), max(ry)], "label": label_ellipse(),
            "needle": [bx0, 1 - by1, bx1, 1 - by0], "lead": LEAD, "track": TRACK, "lifts": LIFTS,
            "placard": ndc((0, -0.64, tz - 0.035))[1],
            "record_quad": record_quad()}
    json.dump(geom, open(os.path.join(S, "room-geometry.json"), "w")); print("GEOM", json.dumps(geom)); print("ANGLES", math.degrees(A_IN), math.degrees(A_OUT), "rest", math.degrees(REST))

if MODE == "intro":
    arm_pose(REST)
    # lit exactly as the still is: the wall dark and a hole for the live wall
    # (the app adds its light from the light film), the record and label
    # holes for the app's pressing
    face.data.materials[0] = face_dark; face.is_holdout = True
    rec.is_holdout = True; lab.is_holdout = True
    back.is_shadow_catcher = True                     # the app's background shows through the wall
    sc.render.film_transparent = True
    sc.cycles.samples = 16 if PROBE else 48
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (780, 1688)
    opening_camera()
    sc.frame_start, sc.frame_end = 1, 108
    # where the wall and the record are in every frame, for the app to draw on;
    # the wall is out of shot while the camera is close on the deck
    track = []
    for f in range(1, 109):
        sc.frame_set(f); bpy.context.view_layer.update()
        track.append({"face": face_quad() if face_visible() else None, "label": label_ellipse(), "badge": [], "record": record_quad()})
    json.dump({"fps": 30, "frames": track}, open(os.path.join(S, "room-intro-track.json"), "w"))
    if os.environ.get("INTRO_PROBE"):
        for f in [int(x) for x in os.environ["INTRO_PROBE"].split(",")]:
            sc.frame_set(f)
            sc.render.filepath = os.path.join(S, "intro-probe-%d%s.png" % (f, os.environ.get("PROBE_TAG", ""))); bpy.ops.render.render(write_still=True)
    else:
        os.makedirs(os.path.join(S, "room-intro"), exist_ok=True)
        sc.render.filepath = os.path.join(S, "room-intro", "room_"); bpy.ops.render.render(animation=True)
print("DONE", MODE)
