# The room, rendered: the mockup's framing, one to one, with a real record
# player on the table. Outputs, by mode (argument after --):
#   base    the still the app sits on, 3x, from the final camera
#   light   how the wall's light falls, alone, for tinting in the app
#   spin    one turn of the record, transparent, cropped, 54 frames
#   intro   the opening: lid up, the mark assembles, lid closes, pull back
#   geom    where the wall face and the record are, in the base image
import bpy, math, os, sys, json, random
from mathutils import Vector, Matrix
from bpy_extras.object_utils import world_to_camera_view

S = os.path.dirname(os.path.abspath(__file__))
COVER = os.path.join(S, "cover.jpg")
MODE = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "base"
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
plinth = box("plinth", (0.46, 0.37, 0.058), (px, py, top + 0.029), lacquer, bevel=0.005)
for dx, dy in ((-0.20, -0.15), (0.20, -0.15), (-0.20, 0.15), (0.20, 0.15)):
    cyl("foot", 0.016, 0.010, (px + dx, py + dy, top - 0.005), rubber, verts=48)
pc = (px - 0.03, py)
cyl("platter", 0.153, 0.014, (pc[0], pc[1], top + 0.058 + 0.007), alu, verts=160, bevel=0.0015)
cyl("strobe", 0.1545, 0.006, (pc[0], pc[1], top + 0.058 + 0.007), alu, verts=160)
cyl("slipmat", 0.145, 0.0028, (pc[0], pc[1], top + 0.058 + 0.0154), felt, verts=160)
rec = cyl("record", 0.150, 0.0022, (pc[0], pc[1], top + 0.058 + 0.0179), vinyl, verts=200)
lab = cyl("label", 0.0505, 0.0008, (0, 0, 0.0015), label_m, verts=96); lab.parent = rec
cyl("spindle", 0.0036, 0.018, (pc[0], pc[1], top + 0.058 + 0.024), chrome, verts=32)
cyl("puck", 0.019, 0.005, (px - 0.19, py + 0.135, top + 0.058 + 0.0025), alu, verts=48)
cyl("power", 0.011, 0.007, (px - 0.19, py - 0.14, top + 0.058 + 0.0035), alu, verts=48)
cyl("led", 0.0018, 0.0005, (px - 0.17, py - 0.155, top + 0.058 + 0.0003), amber, verts=16)
bx, by = px + 0.165, py + 0.115
cyl("arm_base", 0.024, 0.012, (bx, by, top + 0.058 + 0.006), black, verts=64)
cyl("arm_pivot", 0.011, 0.026, (bx, by, top + 0.058 + 0.025), chrome, verts=48)
tip = (pc[0] + 0.105, py - 0.06, top + 0.058 + 0.029)     # the headshell 3 mm off the vinyl
piv = (bx, by, top + 0.058 + 0.036)
dx, dy, dz = tip[0] - piv[0], tip[1] - piv[1], tip[2] - piv[2]
L = math.sqrt(dx * dx + dy * dy + dz * dz)
mid = ((piv[0] + tip[0]) / 2, (piv[1] + tip[1]) / 2, (piv[2] + tip[2]) / 2)
ARM_DX, ARM_DY = dx, dy
# the arm is built about its pivot, with the pivot at the origin, and the
# pivot is then carried to its post: no parent inverse to get stale
armpivot = bpy.data.objects.new("armpivot", None); bpy.context.collection.objects.link(armpivot)
armpivot.location = (0, 0, 0)
rel = lambda p: (p[0] - piv[0], p[1] - piv[1], p[2] - piv[2])
arm_parts = [
    cyl("tonearm", 0.0036, L, rel(mid), chrome, rot=(0, math.acos(dz / L), math.atan2(dy, dx)), verts=24),
    box("headshell", (0.03, 0.012, 0.008), rel((tip[0], tip[1], tip[2] - 0.003)), alu, bevel=0.001),
    box("cartridge", (0.016, 0.010, 0.006), rel((tip[0] + 0.004, tip[1], tip[2] - 0.009)), black, bevel=0.0006),
    cyl("stylus", 0.0006, 0.006, rel((tip[0] + 0.010, tip[1], tip[2] - 0.013)), chrome, rot=(0, math.radians(35), 0), verts=8),
]
cw = (piv[0] - dx * 0.24, piv[1] - dy * 0.24, piv[2] + 0.001)
arm_parts.append(cyl("counterweight", 0.011, 0.02, rel(cw), chrome, rot=(0, math.pi / 2, math.atan2(dy, dx)), verts=48))
for o in arm_parts:
    o.parent = armpivot; o.matrix_parent_inverse = Matrix.Identity(4)
armpivot.location = piv
cyl("cue", 0.0035, 0.024, (bx - 0.032, by - 0.014, top + 0.058 + 0.02), chrome, verts=16)
cyl("antiskate", 0.006, 0.008, (bx + 0.03, by - 0.018, top + 0.058 + 0.004), black, verts=32)
# where the arm sleeps: a post with a cradle, off the record's edge
REST = math.radians(23)
cyl("armrest", 0.005, 0.019, (0.152, -0.402, top + 0.058 + 0.0095), black, verts=24)
box("cradle", (0.014, 0.010, 0.006), (0.152, -0.402, top + 0.058 + 0.022), black)
# the lift is a tilt about the bearing, not a rise of the whole arm: the
# stylus comes up, the counterweight dips a little, the pivot stays put
ARM_ACROSS = Vector((ARM_DY, -ARM_DX, 0)).normalized()     # across the arm, level
def arm_pose(angle, lift=0.0):
    tilt = -math.asin(max(-1.0, min(1.0, lift / L)))
    armpivot.matrix_world = (Matrix.Translation(Vector(piv)) @ Matrix.Rotation(angle, 4, 'Z')
                             @ Matrix.Rotation(tilt, 4, ARM_ACROSS))
bpy.ops.mesh.primitive_cube_add(size=1, location=(px, py, top + 0.058 + 0.05))
lid = bpy.context.active_object; lid.name = "dustcover"; lid.scale = (0.462, 0.372, 0.10)
bpy.ops.object.transform_apply(scale=True)
import bmesh
bm = bmesh.new(); bm.from_mesh(lid.data)
bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.z < -0.9], context='FACES')
bm.to_mesh(lid.data); bm.free(); lid.data.update()
sol = lid.modifiers.new("shell", 'SOLIDIFY'); sol.thickness = 0.0035; sol.offset = -1
lb = lid.modifiers.new("edge", 'BEVEL'); lb.width = 0.004; lb.segments = 3
lid.data.materials.append(acrylic); bpy.ops.object.shade_smooth_by_angle()
bpy.context.scene.cursor.location = (px, py + 0.186, top + 0.058)
bpy.ops.object.origin_set(type='ORIGIN_CURSOR')

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

# the mark: nine small plates on the front of the dust cover, a badge, the
# middle one the bright one, as the app draws it. They belong to the cover.
HINGE = (px, py + 0.186, top + 0.058)
# on the top of the cover, at its left, toward the back: raised tiles, so
# their faces show from the seat where a flat print would foreshorten away
BADGE = (-0.160, -0.075)                  # x, y from the hinge, on the top
plates = []
for i in range(9):
    gx, gy = i % 3 - 1, 1 - i // 3
    local = (BADGE[0] + gx * 0.042, BADGE[1] + gy * 0.042, 0.10 + 0.003)
    p = box(f"plate{i}", (0.030, 0.030, 0.006), (HINGE[0] + local[0], HINGE[1] + local[1], HINGE[2] + local[2]),
            plate_mid if i == 4 else plate_m, bevel=0.0008)
    p.location = local; p.parent = lid; p.matrix_parent_inverse = Matrix.Identity(4)
    plates.append((p, local))
LID_UP = math.radians(-78)                # nearly upright, the badge square to the seat
def hide_cover():
    lid.hide_render = True
    for p, h in plates: p.hide_render = True

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
    m = lab.matrix_world; c = m @ Vector((0, 0, 0)); ax = m @ Vector((0.0505, 0, 0)); ay = m @ Vector((0, 0.0505, 0))
    c2, a2, b2 = ndc(c), ndc(ax), ndc(ay); return [c2[0], c2[1], a2[0] - c2[0], a2[1] - c2[1], b2[0] - c2[0], b2[1] - c2[1]]
def record_quad():
    # the square the record sits in, on its own plane: the app draws the
    # pressing through it, so the disc lands on the platter in perspective
    m = rec.matrix_world; z = 0.0011
    return [ndc(m @ Vector((sx * 0.150, sy * 0.150, z))) for sx, sy in ((-1, 1), (1, 1), (1, -1), (-1, -1))]
def badge_quads():
    out = []
    for p, h in plates:
        m = p.matrix_world
        out.append([ndc(m @ Vector((sx * 0.015, sy * 0.015, 0.003))) for sx, sy in ((-1, 1), (1, 1), (1, -1), (-1, -1))])
    return out
def cover_border(pad=0.02):
    pts = []
    for o in [lid] + [p for p, h in plates]:
        pts += [world_to_camera_view(sc, cam, o.matrix_world @ v.co) for v in o.data.vertices]
    x0, x1 = min(p.x for p in pts), max(p.x for p in pts); y0, y1 = min(p.y for p in pts), max(p.y for p in pts)
    return (max(0, x0 - pad), max(0, y0 - pad), min(1, x1 + pad), min(1, y1 + pad))

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
    lid.rotation_euler = (0, 0, 0)
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
R_IN, R_OUT = 0.146, 0.064
def stylus_radius(angle):
    c, s_ = math.cos(angle), math.sin(angle)
    x = piv[0] + ARM_DX * c - ARM_DY * s_; y = piv[1] + ARM_DX * s_ + ARM_DY * c
    return math.hypot(x - pc[0], y - pc[1])
def angle_for(radius):
    lo, hi = -0.7, REST                     # radius grows with the angle
    for _ in range(48):
        m = (lo + hi) / 2
        if stylus_radius(m) < radius: lo = m
        else: hi = m
    return (lo + hi) / 2
A_IN, A_OUT = angle_for(R_IN), angle_for(R_OUT)
def needle_angle(i):
    if i < LEAD: return REST + (A_IN - REST) * (i / (LEAD - 1))
    return angle_for(R_IN + (R_OUT - R_IN) * ((i - LEAD) / (TRACK - 1)))
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
        arm_pose(needle_angle(i), UP * l / (LIFTS - 1)); bpy.context.view_layer.update()
        for o in arm_parts:
            pts += [world_to_camera_view(sc, cam, o.matrix_world @ v.co) for v in o.data.vertices]
    pad = 0.02                               # room for the shadow, more below it
    x0, x1 = min(p.x for p in pts), max(p.x for p in pts); y0, y1 = min(p.y for p in pts), max(p.y for p in pts)
    return (max(0, x0 - pad), max(0, y0 - pad * 1.6), min(1, x1 + pad), min(1, y1 + pad))

if MODE == "needle":
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.name not in ("tonearm", "headshell", "cartridge", "stylus", "counterweight"): o.hide_render = True
    hide_cover()
    # what the arm's shadow falls on stays, as a catcher: only the shadow shows
    for name in ("record", "label", "slipmat", "platter", "strobe", "plinth", "top", "cradle", "armrest"):
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
        arm_pose(needle_angle(i), UP * l / (LIFTS - 1)); bpy.context.view_layer.update()
        sc.render.filepath = f; bpy.ops.render.render(write_still=True)

if MODE == "base":
    for o in arm_parts: o.hide_render = True
    hide_cover(); face.data.materials[0] = face_dark
    back.is_shadow_catcher = True; sc.render.film_transparent = True
    sc.cycles.samples = 16 if PROBE else 200
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (1170, 2532)
    sc.render.filepath = os.path.join(S, "room-base.png"); bpy.ops.render.render(write_still=True)

if MODE == "light":
    face.visible_camera = False
    for o in arm_parts: o.hide_render = True
    hide_cover()
    for o in bpy.data.objects:
        if o.type == 'LIGHT': o.hide_render = True
    wbg.inputs[1].default_value = 0.0
    face.data.materials[0] = white_led
    sc.cycles.samples = 16 if PROBE else 160
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (1170, 2532)
    sc.render.filepath = os.path.join(S, "room-light.png"); bpy.ops.render.render(write_still=True)

if MODE == "cover":
    keep = {lid.name}
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.name not in keep: o.hide_render = True
    for name in ("plinth", "platter", "strobe", "record", "label", "slipmat", "top"):
        o = bpy.data.objects.get(name)
        if o: o.hide_render = False; o.is_shadow_catcher = True
    face.data.materials[0] = face_dark
    e = amber.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]; e.default_value = 1.2
    e2 = amber_soft.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]; e2.default_value = 0.35
    sc.render.film_transparent = True
    sc.render.resolution_x, sc.render.resolution_y = 1170, 2532
    bx0, by0, bx1, by1 = cover_border(pad=0.09)
    sc.render.use_border = True; sc.render.use_crop_to_border = True
    sc.render.border_min_x, sc.render.border_max_x = bx0, bx1
    sc.render.border_min_y, sc.render.border_max_y = by0, by1
    json.dump({"cover": [bx0, 1 - by1, bx1, 1 - by0]}, open(os.path.join(S, "room-cover.json"), "w"))
    sc.cycles.samples = 16 if PROBE else 128
    sc.render.filepath = os.path.join(S, "room-cover.png"); bpy.ops.render.render(write_still=True)

if MODE == "badge":
    # the plates alone, white, on the closed cover: the app tints them with
    # the wall's colour, and they keep their bevels and their shading
    keep = {p.name for p, h in plates}
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.name not in keep: o.hide_render = True
    lid.hide_render = False; lid.is_shadow_catcher = True
    for i, (p, h) in enumerate(plates): p.hide_render = False; p.data.materials[0] = plate_white_lit if i == 4 else plate_white
    sc.render.film_transparent = True
    sc.render.resolution_x, sc.render.resolution_y = 1170, 2532
    pts = []
    for p, h in plates: pts += [world_to_camera_view(sc, cam, p.matrix_world @ v.co) for v in p.data.vertices]
    pad = 0.012
    bx0, bx1 = max(0, min(q.x for q in pts) - pad), min(1, max(q.x for q in pts) + pad)
    by0, by1 = max(0, min(q.y for q in pts) - pad), min(1, max(q.y for q in pts) + pad)
    sc.render.use_border = True; sc.render.use_crop_to_border = True
    sc.render.border_min_x, sc.render.border_max_x = bx0, bx1
    sc.render.border_min_y, sc.render.border_max_y = by0, by1
    json.dump({"badge_box": [bx0, 1 - by1, bx1, 1 - by0]}, open(os.path.join(S, "room-badge.json"), "w"))
    sc.cycles.samples = 16 if PROBE else 128
    sc.render.filepath = os.path.join(S, "room-badge.png"); bpy.ops.render.render(write_still=True)

if MODE == "recshade":
    # the record and its label in matte white, lit by the room, with the
    # platter and plinth as catchers: what the pressing is multiplied by
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.name not in ("record", "label"): o.hide_render = True
    for name in ("platter", "strobe", "slipmat", "plinth", "spindle"):
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
OVER = (pc[0], pc[1] - OVER_DY, top + 0.058 + 0.018 + OVER_H)
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
    lid.rotation_euler = (LID_UP, 0, 0); arm_pose(REST)
    bpy.context.view_layer.update()
def dive_path():
    cam.location = SEAT[0]; aim(cam, SEAT[1], frame=1)
    cam.location = OVER; cam.rotation_euler = (0, 0, 0)
    cam.keyframe_insert("location", frame=DIVE_N); cam.keyframe_insert("rotation_euler", frame=DIVE_N)
    ease_all(cam)
    lid.rotation_euler = (0, 0, 0); lid.keyframe_insert("rotation_euler", frame=3)
    lid.rotation_euler = (LID_UP, 0, 0); lid.keyframe_insert("rotation_euler", frame=DIVE_N - 6)
    ease_all(lid)
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
        for name in ("platter", "strobe", "slipmat", "plinth", "spindle", lid.name):
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
        face.visible_camera = False
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

if MODE in ("dive", "divelight", "divebadge"):
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
        face.visible_camera = False
        for pl, h in plates: pl.hide_render = True
        wbg.inputs[1].default_value = 0.0
        face.data.materials[0] = white_led
        sc.render.film_transparent = False
        sc.cycles.samples = 16 if PROBE else 32
        prefix = "light_"
    if MODE == "divebadge":
        keep = {p.name for p, h in plates}
        for o in bpy.data.objects:
            if o.type == 'MESH' and o.name not in keep: o.hide_render = True
        lid.hide_render = False; lid.is_shadow_catcher = True
        for i, (p, h) in enumerate(plates): p.hide_render = False; p.data.materials[0] = plate_white_lit if i == 4 else plate_white
        sc.render.film_transparent = True
        sc.cycles.samples = 16 if PROBE else 32
        prefix = "plates_"
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
if MODE in ("mark", "marklight", "markbadge"):
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
        face.data.materials[0] = white_led; face.visible_camera = False
        st = white_led.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
        st.default_value = 0.0; st.keyframe_insert("default_value", frame=70)
        st.default_value = 2.5; st.keyframe_insert("default_value", frame=92)
        sc.render.film_transparent = False
        sc.cycles.samples = 16 if PROBE else 32
        prefix = "light_"
    if MODE == "markbadge":
        keep = {m.name for m in marks} | {p.name for p, h in plates}
        for o in bpy.data.objects:
            if o.type == 'MESH' and o.name not in keep: o.hide_render = True
        lid.hide_render = False; lid.is_shadow_catcher = True; lid.animation_data_clear()
        wf.animation_data_clear(); wf.hide_render = True          # keyframed, so it must be told twice
        for i, (p, h) in enumerate(plates): p.data.materials[0] = plate_white_lit if i == 4 else plate_white
        sc.cycles.samples = 16 if PROBE else 32
        prefix = "plates_"
    if os.environ.get("MARK_PROBE"):
        for f in [int(x) for x in os.environ["MARK_PROBE"].split(",")]:
            sc.frame_set(f); bpy.context.view_layer.update()
            sc.render.filepath = os.path.join(S, "mark-probe-%s%02d.png" % (prefix, f)); bpy.ops.render.render(write_still=True)
    else:
        os.makedirs(os.path.join(S, "room-" + MODE), exist_ok=True)
        sc.render.filepath = os.path.join(S, "room-" + MODE, prefix); bpy.ops.render.render(animation=True)

if MODE == "lightfilm":
    face.visible_camera = False
    # the opening's light pass: the room lit by a white wall alone, nothing
    # else, black elsewhere; the app tints it with the sleeve and screens it
    arm_pose(REST)
    for o in bpy.data.objects:
        if o.type == 'LIGHT': o.hide_render = True
    for pl, h in plates: pl.hide_render = True
    wbg.inputs[1].default_value = 0.0
    face.data.materials[0] = white_led
    sc.render.film_transparent = False
    sc.cycles.samples = 32
    sc.render.resolution_x, sc.render.resolution_y = 780, 1688
    lid.rotation_euler = (LID_UP, 0, 0); lid.keyframe_insert("rotation_euler", frame=58)
    lid.rotation_euler = (0, 0, 0); lid.keyframe_insert("rotation_euler", frame=84)
    ease_all(lid)
    rx = Matrix.Rotation(LID_UP, 3, 'X')
    badge_w = Vector(HINGE) + rx @ Vector((BADGE[0], BADGE[1], 0.103))
    inward = rx @ Vector((0, 0, -1))
    close_at = badge_w + inward * 0.60 + Vector((0, 0, 0.04))
    cam.location = close_at; aim(cam, badge_w, frame=64)
    cam.location = SEAT[0]; aim(cam, SEAT[1], frame=108)
    ease_all(cam)
    sc.frame_start, sc.frame_end = 1, 108
    os.makedirs(os.path.join(S, "room-lightfilm"), exist_ok=True)
    sc.render.filepath = os.path.join(S, "room-lightfilm", "light_"); bpy.ops.render.render(animation=True)

if MODE == "badgefilm":
    # the opening's plates alone, white, per frame: the app tints them
    arm_pose(REST)
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.name not in {p.name for p, h in plates}: o.hide_render = True
    for i, (p, h) in enumerate(plates): p.hide_render = False; p.data.materials[0] = plate_white_lit if i == 4 else plate_white
    sc.render.film_transparent = True
    sc.cycles.samples = 24
    sc.render.resolution_x, sc.render.resolution_y = 780, 1688
    lid.rotation_euler = (LID_UP, 0, 0); lid.keyframe_insert("rotation_euler", frame=58)
    lid.rotation_euler = (0, 0, 0); lid.keyframe_insert("rotation_euler", frame=84)
    ease_all(lid)
    rx = Matrix.Rotation(LID_UP, 3, 'X')
    badge_w = Vector(HINGE) + rx @ Vector((BADGE[0], BADGE[1], 0.103))
    inward = rx @ Vector((0, 0, -1))
    close_at = badge_w + inward * 0.60 + Vector((0, 0, 0.04))
    cam.location = close_at; aim(cam, badge_w, frame=64)
    cam.location = SEAT[0]; aim(cam, SEAT[1], frame=108)
    ease_all(cam)
    for i, (p, home) in enumerate(plates):
        away = (home[0] + random.uniform(-0.26, 0.26), home[1] + random.uniform(-0.30, -0.02), home[2] + random.uniform(-0.12, 0.30))
        p.location = away; p.scale = (0.05, 0.05, 0.05)
        p.rotation_euler = (random.uniform(-2.5, 2.5), random.uniform(-2.5, 2.5), random.uniform(-2.5, 2.5))
        f0 = 2 + i * 3
        for k in ("location", "scale", "rotation_euler"): p.keyframe_insert(k, frame=f0)
        p.location = home; p.scale = (1, 1, 1); p.rotation_euler = (0, 0, 0)
        for k in ("location", "scale", "rotation_euler"): p.keyframe_insert(k, frame=f0 + 24)
        ease_all(p)
    sc.frame_start, sc.frame_end = 1, 108
    os.makedirs(os.path.join(S, "room-badgefilm"), exist_ok=True)
    sc.render.filepath = os.path.join(S, "room-badgefilm", "badge_"); bpy.ops.render.render(animation=True)

if MODE == "geom":
    sc.render.resolution_x, sc.render.resolution_y = 1170, 2532
    corners = face_quad()
    rn = [ndc(rec.matrix_world @ v.co) for v in rec.data.vertices]
    rx = [p[0] for p in rn]; ry = [p[1] for p in rn]
    bx0, by0, bx1, by1 = needle_border()
    cx0, cy0, cx1, cy1 = cover_border(pad=0.09)
    geom = {"face": corners, "record": [min(rx), min(ry), max(rx), max(ry)], "label": label_ellipse(),
            "needle": [bx0, 1 - by1, bx1, 1 - by0], "lead": LEAD, "track": TRACK, "lifts": LIFTS,
            "cover": [cx0, 1 - cy1, cx1, 1 - cy0], "placard": ndc((0, -0.64, tz - 0.035))[1],
            "badge": badge_quads(), "record_quad": record_quad()}
    json.dump(geom, open(os.path.join(S, "room-geometry.json"), "w")); print("GEOM", json.dumps(geom)); print("ANGLES", math.degrees(A_IN), math.degrees(A_OUT), "rest", math.degrees(REST))

if MODE == "intro":
    arm_pose(REST)
    # the wall is a hole with light behind it: the app draws the live wall
    # through it, and the room is lit as if by a white wall
    # lit exactly as the still is: the wall dark (the app adds its light from
    # the light film), the record and label holes for the app's pressing,
    # the plates left to their own film for the app to tint
    face.data.materials[0] = face_dark; face.is_holdout = True
    rec.is_holdout = True; lab.is_holdout = True
    for pl, h in plates: pl.hide_render = True
    # the wall's own light, kept low here: at ten it reflected in the raised
    # glass as a white sheen that bleached the live wall behind it
    white_led.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 2.5
    back.is_shadow_catcher = True                     # the app's background shows through the wall
    sc.render.film_transparent = True
    sc.cycles.samples = 16 if PROBE else 48
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (780, 1688)
    lid.rotation_euler = (LID_UP, 0, 0); lid.keyframe_insert("rotation_euler", frame=58)
    lid.rotation_euler = (0, 0, 0); lid.keyframe_insert("rotation_euler", frame=84)
    ease_all(lid)
    # the close shot is on the badge itself: where it is with the cover up,
    # seen from straight in front through the glass, the wall behind
    rx = Matrix.Rotation(LID_UP, 3, 'X')
    badge_w = Vector(HINGE) + rx @ Vector((BADGE[0], BADGE[1], 0.103))
    inward = rx @ Vector((0, 0, -1))
    close_at = badge_w + inward * 0.60 + Vector((0, 0, 0.04))
    cam.location = close_at; aim(cam, badge_w, frame=64)              # the badge dead centre
    cam.location = SEAT[0]; aim(cam, SEAT[1], frame=108)
    ease_all(cam)
    # the plates fly in, in the cover's own space, and settle as its badge
    for i, (p, home) in enumerate(plates):
        away = (home[0] + random.uniform(-0.26, 0.26), home[1] + random.uniform(-0.30, -0.02), home[2] + random.uniform(-0.12, 0.30))
        p.location = away; p.scale = (0.05, 0.05, 0.05)
        p.rotation_euler = (random.uniform(-2.5, 2.5), random.uniform(-2.5, 2.5), random.uniform(-2.5, 2.5))
        f0 = 2 + i * 3
        for k in ("location", "scale", "rotation_euler"): p.keyframe_insert(k, frame=f0)
        p.location = home; p.scale = (1, 1, 1); p.rotation_euler = (0, 0, 0)
        for k in ("location", "scale", "rotation_euler"): p.keyframe_insert(k, frame=f0 + 24)
        ease_all(p)
    e = plate_mid.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
    e2 = plate_m.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"]
    for f, v in ((1, 0.0), (30, 0.0), (46, 1.6), (56, 0.6), (108, 0.6)):
        e.default_value = v; e.keyframe_insert("default_value", frame=f)
    for f, v in ((1, 0.0), (24, 0.0), (44, 0.5), (56, 0.2), (108, 0.2)):
        e2.default_value = v; e2.keyframe_insert("default_value", frame=f)
    sc.frame_start, sc.frame_end = 1, 108
    # where the wall and the label are in every frame, for the app to draw on
    track = []
    for f in range(1, 109):
        sc.frame_set(f); bpy.context.view_layer.update()
        track.append({"face": face_quad(), "label": label_ellipse(), "badge": badge_quads(), "record": record_quad()})
    json.dump({"fps": 30, "frames": track}, open(os.path.join(S, "room-intro-track.json"), "w"))
    if os.environ.get("INTRO_PROBE"):
        for f in [int(x) for x in os.environ["INTRO_PROBE"].split(",")]:
            sc.frame_set(f)
            sc.render.filepath = os.path.join(S, "intro-probe-%d%s.png" % (f, os.environ.get("PROBE_TAG", ""))); bpy.ops.render.render(write_still=True)
    else:
        os.makedirs(os.path.join(S, "room-intro"), exist_ok=True)
        sc.render.filepath = os.path.join(S, "room-intro", "room_"); bpy.ops.render.render(animation=True)
print("DONE", MODE)
