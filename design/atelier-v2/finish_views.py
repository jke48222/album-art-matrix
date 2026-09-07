import bpy, os, math, json
ROOT=os.path.dirname(os.path.abspath(__file__))
bpy.ops.wm.open_mainfile(filepath=os.path.join(ROOT,'Tessera-Atelier.blend'))
s=bpy.context.scene
cols={c.name:c for c in bpy.data.collections}
cams={key:next(o for o in s.objects if o.type=='CAMERA' and o.name.startswith(key[:2]+' ')) for key in ['01-hero','02-listening-room','03-corner-detail','04-rear-service','05-exploded','06-dimensions','07-controller','08-album-mode']}
cams['06-dimensions'].data.ortho_scale=1.08
screen=bpy.data.objects['192px optical appearance proxy / not measured']
disc=bpy.data.materials['192px emissive display appearance disc192.png'];album=disc.copy();album.name='192px emissive display appearance album192.png';album.use_fake_user=True
for node in album.node_tree.nodes:
 if node.type=='TEX_IMAGE':node.image=bpy.data.images.load(os.path.join(ROOT,'album192.png'))
# Replace failed curved-curve boolean with closed manifold slot cutters.
old=bpy.data.objects.get('PSU punched steel cover')
if old:bpy.data.objects.remove(old,do_unlink=True)
def cube(name,d,p):
 bpy.ops.mesh.primitive_cube_add(size=1,location=p);o=bpy.context.object;o.name=name;o.dimensions=d;bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
 for c in list(o.users_collection):c.objects.unlink(o)
 cols['E Power'].objects.link(o);return o
top=cube('PSU punched steel cover',(.203,.001,.1126),(-.092,-.0255,-.158));top.data.materials.append(bpy.data.materials['Brushed aluminium'])
def subtract(cut):
 mod=top.modifiers.new('Ventilation aperture','BOOLEAN');mod.operation='DIFFERENCE';mod.solver='EXACT';mod.object=cut;bpy.context.view_layer.objects.active=top;bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cut,do_unlink=True)
for rad in [.015,.023]:
 for q in range(4):
  pts=[]
  for rr,angles in [(rad+.0028,range(25)),(rad-.0028,reversed(range(25)))]:
   for j in angles:
    t=math.radians(q*90+10+j*70/24);pts.append((-.03795+rr*math.cos(t),-.1372+rr*math.sin(t)))
  n=len(pts);vs=[(x,y,z) for y in [-.029,-.022] for x,z in pts];fs=[tuple(reversed(range(n))),tuple(range(n,2*n))]+[(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
  me=bpy.data.meshes.new('Closed annular slot');me.from_pydata(vs,[],fs);me.update();cut=bpy.data.objects.new('Slot cutter',me);s.collection.objects.link(cut)
  import bmesh
  bm=bmesh.new();bm.from_mesh(me);bmesh.ops.recalc_face_normals(bm,faces=bm.faces);bm.to_mesh(me);bm.free();subtract(cut)
for x in [-.167,-.141]:
 for z in [-.176,-.158,-.140]:subtract(cube('Slot cutter',(.018,.007,.003),(x,-.0255,z)))
top['verification']='Manufacturer overall envelope; visually reconstructed slot pattern'
# Refresh notes inside the deliverable.
t=bpy.data.texts.get('READ FIRST - verification and design decisions');t.clear();t.write(open(os.path.join(ROOT,'MODEL-NOTES.txt')).read())
p=bpy.context.preferences.addons['cycles'].preferences;p.compute_device_type='METAL';p.get_devices()
for d in p.devices:d.use=d.type=='METAL'
if hasattr(p,'kernel_optimization_level'):p.kernel_optimization_level='OFF'
s.cycles.device='GPU';s.cycles.samples=48
base=['A Exterior','O Optics','O Diffuser','P Panels','C Carrier','E Power','E Bus bars','K Bus covers','D Controller','H Harness','S Sensors','G Mains guard','R Rear cover','M Mount','U Unresolved fit','V Display appearance','Z Studio']
def show(names):
 for n,c in cols.items():c.hide_render=n not in names;c.hide_viewport=n not in names
show(base+['Z Room']);s.camera=cams['01-hero'];bpy.ops.file.pack_all();bpy.ops.wm.save_as_mainfile(filepath=os.path.join(ROOT,'Tessera-Atelier.blend'))
# Render subset can be specified after -- for iteration.
import sys
requested=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else list(cams)
for name in requested:
 visible=base.copy();moves={};screen.data.materials[0]=disc
 if name in ['01-hero','02-listening-room','03-corner-detail','08-album-mode']:visible+=['Z Room']
 if name=='02-listening-room':visible+=['Z Furniture']
 if name=='08-album-mode':screen.data.materials[0]=album
 if name=='04-rear-service':visible=[n for n in base if n not in ['R Rear cover','G Mains guard','K Bus covers','V Display appearance']]
 if name=='05-exploded':
  visible=[n for n in base if n not in ['H Harness','V Display appearance','U Unresolved fit','K Bus covers']]
  moves={'O Optics':-.45,'O Diffuser':-.32,'P Panels':-.18,'A Exterior':.24,'R Rear cover':.37,'M Mount':.45}
 if name=='06-dimensions':visible+=['Q Dimensions']
 if name=='07-controller':visible=['D Controller','Z Studio']
 show(visible)
 for cn,dy in moves.items():
  for o in cols[cn].objects:o.location.y+=dy
 s.camera=cams[name];s.render.filepath=os.path.join(ROOT,name+'.png');s.render.resolution_x=2400 if name=='02-listening-room' else 2200;s.render.resolution_y=1800
 bpy.ops.render.render(write_still=True)
 for cn,dy in moves.items():
  for o in cols[cn].objects:o.location.y-=dy
show(base+['Z Room']);screen.data.materials[0]=disc;s.camera=cams['01-hero']
for screenui in bpy.data.screens:
 for a in screenui.areas:
  if a.type=='VIEW_3D':a.spaces.active.region_3d.view_perspective='CAMERA'
bpy.ops.file.pack_all();bpy.ops.wm.save_as_mainfile(filepath=os.path.join(ROOT,'Tessera-Atelier.blend'))
print('ATELIER COMPLETE',len(s.objects),'objects',flush=True)
