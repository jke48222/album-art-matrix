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
vinyl = mat("vinyl", (0.018, 0.018, 0.021), 0.34)
chrome = mat("chrome", (0.85, 0.85, 0.85), 0.18, 1.0)
black = mat("black", (0.03, 0.03, 0.03), 0.5)
rubber = mat("rubber", (0.03, 0.03, 0.03), 0.9)
frame_m = mat("frame", (0.32, 0.32, 0.32), 0.55)
acrylic = mat("acrylic", (0.88, 0.94, 1.0), 0.06, alpha=0.12, ior=1.49)
amber = mat("amber", (0.2, 0.15, 0.06), 0.4, emission=(0.93, 0.62, 0.18), strength=0.0)
amber_soft = mat("amber_soft", (0.16, 0.12, 0.05), 0.4, emission=(0.93, 0.62, 0.18), strength=0.0)
plate_m = mat("plate", (0.82, 0.80, 0.76), 0.3, emission=(1.0, 0.98, 0.94), strength=0.0)
plate_mid = mat("plate_mid", (0.86, 0.84, 0.80), 0.3, emission=(1.0, 0.98, 0.94), strength=0.0)
cover = bpy.data.images.load(COVER)
label_m = mat("label", (0.93, 0.91, 0.86), 0.7)      # paper: the app lays the sleeve on it
face_dark = mat("face_dark", (0.012, 0.012, 0.012), 0.45)

def grooves():
    # The record's face as a roughness map: a glossy lip, a smooth lead-in,
    # five bands of fine grooves with the smoother, brighter spaces between
    # them a real pressing has, a smooth run-out, and the label's paper.
    # Under the light, the fine bands go matte and the spaces shine.
    T = 1024; img = bpy.data.images.new("grooves", T, T); buf = [0.0] * (T * T * 4)
    bands = [(0.930, 0.835), (0.822, 0.720), (0.707, 0.610), (0.597, 0.500), (0.487, 0.405)]
    for y in range(T):
        for x in range(T):
            d = math.hypot(x - T / 2, y - T / 2) / (T / 2)
            if d > 1.0: v = 0.5
            elif d > 0.975: v = 0.20          # the lip, glossy
            elif d > 0.93: v = 0.24           # the lead-in
            elif d < 0.35: v = 0.5            # under the label
            elif d < 0.40: v = 0.25           # the run-out
            else:
                v = 0.24                      # the space between two tracks
                for outer, inner in bands:
                    if inner <= d <= outer:
                        v = 0.31 if (int(d * 1200) % 2 == 0) else 0.45
                        break
            o = (y * T + x) * 4; buf[o] = buf[o + 1] = buf[o + 2] = v; buf[o + 3] = 1
    img.pixels = buf
    nt = vinyl.node_tree; bsdf = nt.nodes["Principled BSDF"]
    tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = img
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Roughness"])
    # the radial sheen every record has under a lamp: the highlight runs
    # across the grooves, not along them
    try:
        tan = nt.nodes.new("ShaderNodeTangent"); tan.direction_type = 'RADIAL'; tan.axis = 'Z'
        nt.links.new(tan.outputs["Tangent"], bsdf.inputs["Tangent"])
        bsdf.inputs["Anisotropic"].default_value = 0.65
    except Exception as e:
        print("no anisotropy:", e)
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
# ---- the tonearm ----------------------------------------------------------
# Built from the stylus up. The one fixed fact is where the stylus touches
# the record: on the vinyl's top face, at a radius the groove decides. Every
# other part is placed above that point with the clearances a real arm has,
# so at rest the needle sits on the record and nothing else reaches it. The
# lift tilts the arm about its bearing, stylus up and counterweight down, and
# the check mode prints the stylus height, so this cannot drift back into
# the platter unnoticed. The earlier arm had its cartridge two millimetres
# into the vinyl and a lift whose sign pushed it deeper.
VINYL = top + 0.058 + 0.0179 + 0.0011          # the record's top face
tip = (pc[0] + 0.105, py - 0.06, VINYL)         # the stylus, on the vinyl
piv = (bx, by, top + 0.058 + 0.040)             # the bearing, atop the post
dx, dy, dz = tip[0] - piv[0], tip[1] - piv[1], tip[2] - piv[2]
L = math.sqrt(dx * dx + dy * dy + dz * dz)      # bearing to stylus
ARM_DX, ARM_DY = dx, dy
FLAT = Vector((dx, dy, 0)).normalized()          # along the arm, level
ACROSS_LOCAL = Vector((dy, -dx, 0)).normalized() # across the arm, level
YAW = math.atan2(dy, dx)
armswing = bpy.data.objects.new("armswing", None); bpy.context.collection.objects.link(armswing)
armpivot = bpy.data.objects.new("armpivot", None); bpy.context.collection.objects.link(armpivot)
armpivot.parent = armswing; armpivot.matrix_parent_inverse = Matrix.Identity(4)
rel = lambda p: (p[0] - piv[0], p[1] - piv[1], p[2] - piv[2])
def ahead(back, z):
    """a point `back` metres behind the stylus along the arm, at height z"""
    return (tip[0] - FLAT.x * back, tip[1] - FLAT.y * back, z)
def track(o, d):
    o.rotation_euler = Vector(d).to_track_quat('Z', 'Y').to_euler()
def rod(name, r, p0, p1, m, verts=16, bevel=None):
    d = Vector(p1) - Vector(p0); c = (Vector(p0) + Vector(p1)) / 2
    o = cyl(name, r, d.length, rel(c), m, verts=verts, bevel=bevel); track(o, d); return o
# the tube: from the bearing to the back of the headshell, above the cartridge
head_rear = ahead(0.027, VINYL + 0.012)
tube = rod("tonearm", 0.0042, piv, head_rear, chrome, verts=32)
# the headshell: a shell over the cartridge, turned in a little at the end
# the way a J arm's is, with the finger lift on its outer edge
head = box("headshell", (0.030, 0.014, 0.005), rel(ahead(0.012, VINYL + 0.012)), alu, bevel=0.0008)
head.rotation_euler = (0, 0, YAW + math.radians(20))
lift_p = ahead(0.012, VINYL + 0.0145)
finger = rod("fingerlift", 0.0008, (lift_p[0] + ACROSS_LOCAL.x * 0.006, lift_p[1] + ACROSS_LOCAL.y * 0.006, lift_p[2]),
             (lift_p[0] + ACROSS_LOCAL.x * 0.013, lift_p[1] + ACROSS_LOCAL.y * 0.013, lift_p[2] + 0.005), chrome, verts=8)
# the cartridge hangs under the shell, its underside 2.5 mm off the vinyl
cart = box("cartridge", (0.017, 0.011, 0.007), rel(ahead(0.003, VINYL + 0.006)), black, bevel=0.0006)
cart.rotation_euler = (0, 0, YAW + math.radians(20))
# the cantilever, from under the cartridge's front down to the vinyl
CANT_ROOT = ahead(0.007, VINYL + 0.0035)
cant = rod("stylus", 0.0004, CANT_ROOT, tip, chrome, verts=8)
CANT_LEN = (Vector(tip) - Vector(CANT_ROOT)).length
# behind the bearing: the stub, and the counterweight riding on it
TUBE_DIR = (Vector(head_rear) - Vector(piv)).normalized()
stub = rod("stub", 0.0030, piv, tuple(Vector(piv) - TUBE_DIR * 0.062), chrome, verts=16)
cw_c = Vector(piv) - TUBE_DIR * 0.050
cwt = cyl("counterweight", 0.0125, 0.024, rel(tuple(cw_c)), chrome, verts=48, bevel=0.0012); track(cwt, TUBE_DIR)
tilt_parts = [tube, head, finger, cart, cant, stub, cwt]
# the bearing does not tilt: a yoke across the arm, sitting on the post
yoke = rod("yoke", 0.0075, tuple(Vector(piv) - ACROSS_LOCAL * 0.011), tuple(Vector(piv) + ACROSS_LOCAL * 0.011), black, verts=32, bevel=0.001)
cap = cyl("yokecap", 0.0055, 0.006, rel((piv[0], piv[1], piv[2] + 0.009)), chrome, verts=24)
swing_parts = [yoke, cap]
arm_parts = tilt_parts + swing_parts
for o in tilt_parts: o.parent = armpivot; o.matrix_parent_inverse = Matrix.Identity(4)
for o in swing_parts: o.parent = armswing; o.matrix_parent_inverse = Matrix.Identity(4)
cyl("cue", 0.0035, 0.024, (bx - 0.032, by - 0.014, top + 0.058 + 0.02), chrome, verts=16)
cyl("antiskate", 0.006, 0.008, (bx + 0.03, by - 0.018, top + 0.058 + 0.004), black, verts=32)
# where the arm sleeps: a post with a cradle, off the record's edge
REST = math.radians(23)
cyl("armrest", 0.005, 0.019, (0.152, -0.402, top + 0.058 + 0.0095), black, verts=24)
box("cradle", (0.014, 0.010, 0.006), (0.152, -0.402, top + 0.058 + 0.022), black)
# the lift is a tilt about the bearing, not a rise of the whole arm: the
# stylus comes up by `lift`, the counterweight dips a little, the yoke stays
# put. Positive is up; the check mode proves it.
def arm_pose(angle, lift=0.0):
    armswing.matrix_world = Matrix.Translation(Vector(piv)) @ Matrix.Rotation(angle, 4, 'Z')
    armpivot.matrix_basis = Matrix.Rotation(math.asin(max(-1.0, min(1.0, lift / L))), 4, ACROSS_LOCAL)
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

side = 0.56; cz = 1.42
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
LID_UP = math.radians(-55)
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

if MODE in ("base", "light", "geom", "needle", "cover", "check"):
    set_final()
PROBE = bool(os.environ.get("PROBE"))

# The needle's places. The stylus sits at a radius from the spindle; the
# groove carries it from the lead-in (146 mm on a twelve inch) to the run-
# out (64 mm), linearly in time, so a song's progress is a radius, and a
# radius is an angle of the arm. Index 0 is the arm on its cradle, 1 to
# LEAD-1 the swing in (arm up), LEAD onward the groove positions.
LEAD, TRACK, LIFTS = 10, 32, 5
UP = 0.012                                    # a cue lever's lift
CRADLE_DROP = -0.0025                         # the cradle sits below the vinyl plane, off the platter
def lift_for(i, l):
    return (CRADLE_DROP if i == 0 else 0.0) + UP * l / (LIFTS - 1)
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
        arm_pose(needle_angle(i), lift_for(i, l)); bpy.context.view_layer.update()
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
        arm_pose(needle_angle(i), lift_for(i, l)); bpy.context.view_layer.update()
        sc.render.filepath = f; bpy.ops.render.render(write_still=True)

if MODE == "check":
    # where the stylus is, in millimetres above the vinyl, at the poses that
    # matter; and two sprites, cropped like the grid, to lay over the room
    for i, l in ((0, 0), (LEAD, 0), (LEAD, LIFTS - 1), (LEAD + 12, 0), (LEAD + TRACK - 1, 0)):
        arm_pose(needle_angle(i), lift_for(i, l)); bpy.context.view_layer.update()
        ends = [cant.matrix_world @ Vector((0, 0, sgn * CANT_LEN / 2)) for sgn in (-1, 1)]
        low = min(ends, key=lambda p: p.z)
        cb = min((cart.matrix_world @ Vector(v.co) for v in cart.data.vertices), key=lambda p: p.z)
        print("CHECK i=%d l=%d stylus %+.2f mm  cartridge underside %+.2f mm  radius %.1f mm" % (
            i, l, (low.z - VINYL) * 1000, (cb.z - VINYL) * 1000, math.hypot(low.x - pc[0], low.y - pc[1]) * 1000))
    for o in bpy.data.objects:
        if o.type == 'MESH' and o not in arm_parts: o.hide_render = True
    hide_cover()
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
    print("NEEDLE border", bx0, by0, bx1, by1)
    sc.cycles.samples = 32
    os.makedirs(os.path.join(S, "check"), exist_ok=True)
    for i, l in ((LEAD + 12, 0), (LEAD + 12, LIFTS - 1), (0, 0)):
        arm_pose(needle_angle(i), lift_for(i, l)); bpy.context.view_layer.update()
        sc.render.filepath = os.path.join(S, "check", "needle-%02d-%d.png" % (i, l)); bpy.ops.render.render(write_still=True)

if MODE == "base":
    for o in arm_parts: o.hide_render = True
    hide_cover(); face.data.materials[0] = face_dark
    back.is_shadow_catcher = True; sc.render.film_transparent = True
    sc.cycles.samples = 16 if PROBE else 200
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (1170, 2532)
    sc.render.filepath = os.path.join(S, "room-base.png"); bpy.ops.render.render(write_still=True)

if MODE == "light":
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
            "badge": badge_quads()}
    json.dump(geom, open(os.path.join(S, "room-geometry.json"), "w")); print("GEOM", json.dumps(geom)); print("ANGLES", math.degrees(A_IN), math.degrees(A_OUT), "rest", math.degrees(REST))

if MODE == "intro":
    arm_pose(REST)
    # the wall is a hole with light behind it: the app draws the live wall
    # through it, and the room is lit as if by a white wall
    face.data.materials[0] = white_led; face.is_holdout = True
    back.is_shadow_catcher = True                     # the app's background shows through the wall
    sc.render.film_transparent = True
    sc.cycles.samples = 16 if PROBE else 48
    sc.render.resolution_x, sc.render.resolution_y = (390, 844) if PROBE else (780, 1688)
    lid.rotation_euler = (LID_UP, 0, 0); lid.keyframe_insert("rotation_euler", frame=58)
    lid.rotation_euler = (0, 0, 0); lid.keyframe_insert("rotation_euler", frame=84)
    ease_all(lid)
    cam.location = CLOSE[0]; aim(cam, CLOSE[1], frame=64)
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
        track.append({"face": face_quad(), "label": label_ellipse(), "badge": badge_quads()})
    json.dump({"fps": 30, "frames": track}, open(os.path.join(S, "room-intro-track.json"), "w"))
    if os.environ.get("INTRO_PROBE"):
        for f in [int(x) for x in os.environ["INTRO_PROBE"].split(",")]:
            sc.frame_set(f)
            sc.render.filepath = os.path.join(S, "intro-probe-%d%s.png" % (f, os.environ.get("PROBE_TAG", ""))); bpy.ops.render.render(write_still=True)
    else:
        os.makedirs(os.path.join(S, "room-intro"), exist_ok=True)
        sc.render.filepath = os.path.join(S, "room-intro", "room_"); bpy.ops.render.render(animation=True)
print("DONE", MODE)
