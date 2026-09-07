"""Independent Codex wall concept. Run with Blender --background --python this_file.
All construction dimensions in mm. Simplified purchased hardware is marked provisional.
"""
import bpy, math, os, json
from mathutils import Vector
ROOT=os.path.dirname(os.path.abspath(__file__))
bpy.ops.wm.read_factory_settings(use_empty=True)
s=bpy.context.scene
s.unit_settings.system='METRIC';s.unit_settings.length_unit='MILLIMETERS'
s.render.engine='CYCLES';s.cycles.samples=32;s.cycles.use_denoising=True
s.render.resolution_x=1600;s.render.resolution_y=1400;s.render.resolution_percentage=100
s.world=bpy.data.worlds.new('Studio world');s.world.color=(.22,.22,.22)
s.view_settings.view_transform='AgX'
cols={}
def col(n):
 if n not in cols:
  c=bpy.data.collections.new(n);s.collection.children.link(c);cols[n]=c
 return cols[n]
def link(o,c):
 for old in list(o.users_collection):old.objects.unlink(o)
 col(c).objects.link(o)
 return o
def mat(n,c,metal=0,rough=.4):
 m=bpy.data.materials.new(n);m.diffuse_color=(*c,1);m.use_nodes=True
 p=m.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=(*c,1);p.inputs['Roughness'].default_value=rough;p.inputs['Metallic'].default_value=metal
 return m
black=mat('Anodized graphite',(.012,.016,.017),.55)
wood=mat('Oiled American walnut',(.16,.067,.029),0,.33)
nt=wood.node_tree;p=nt.nodes.get('Principled BSDF');tc=nt.nodes.new('ShaderNodeTexCoord');vm=nt.nodes.new('ShaderNodeVectorMath');vm.operation='MULTIPLY';vm.inputs[1].default_value=(5,5,160);nt.links.new(tc.outputs['Generated'],vm.inputs[0]);noise=nt.nodes.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=3;nt.links.new(vm.outputs[0],noise.inputs[0]);ramp=nt.nodes.new('ShaderNodeValToRGB');ramp.color_ramp.elements[0].position=.17;ramp.color_ramp.elements[0].color=(.038,.012,.005,1);ramp.color_ramp.elements[1].position=.85;ramp.color_ramp.elements[1].color=(.26,.12,.048,1);nt.links.new(noise.outputs['Fac'],ramp.inputs[0]);nt.links.new(ramp.outputs[0],p.inputs['Base Color'])
silver=mat('Brushed aluminium',(.5,.54,.57),.8,.28);pcb=mat('PCB green',(.02,.15,.063),.15);red=mat('Positive silicone red',(.48,.015,.01));copper=mat('Tinned copper',(.5,.37,.18),.7);nylon=mat('Nylon insulator',(.77,.74,.62));ribbon=mat('IDC grey ribbon',(.21,.24,.26));white=mat('Warm white ink',(.8,.77,.66));wallmat=mat('Limewash warm plaster',(.43,.4,.34),0,.9)
opal=mat('Opal acrylic physical layer',(.78,.8,.76),0,.65);smoke=mat('Smoked ND acrylic physical layer',(.025,.031,.033),0,.22)
for m in [opal,smoke]:m.node_tree.nodes.get('Principled BSDF').inputs['Transmission Weight'].default_value=.8

def box(n,d,p,m=black,c='01 Enclosure',bevel=.5):
 bpy.ops.mesh.primitive_cube_add(size=1,location=tuple(v/1000 for v in p));o=bpy.context.object;o.name=n;o.dimensions=tuple(v/1000 for v in d);bpy.ops.object.transform_apply(location=False,rotation=False,scale=True);o.data.materials.append(m);link(o,c)
 if bevel:
  b=o.modifiers.new('Machined edge','BEVEL');b.width=bevel/1000;b.segments=3;o.modifiers.new('Normals','WEIGHTED_NORMAL')
 o['nominal_dimensions_mm']=list(d)
 return o

def cyl(n,r,h,p,m=black,c='03 Panels',axis='Y'):
 rot=(math.pi/2,0,0) if axis=='Y' else (0,0,0)
 bpy.ops.mesh.primitive_cylinder_add(vertices=20,radius=r/1000,depth=h/1000,location=tuple(v/1000 for v in p),rotation=rot);o=bpy.context.object;o.name=n;o.data.materials.append(m);return link(o,c)
def line(n,pts,m=red,r=1.5,c='06 Harness'):
 cu=bpy.data.curves.new(n,'CURVE');cu.dimensions='3D';cu.bevel_depth=r/1000;cu.bevel_resolution=2;sp=cu.splines.new('POLY');sp.points.add(len(pts)-1)
 for v,p in zip(sp.points,pts):v.co=(*[q/1000 for q in p],1)
 o=bpy.data.objects.new(n,cu);col(c).objects.link(o);o.data.materials.append(m);return o

def text(n,body,p,size=9,m=white,c='09 Dimensions',rear=False):
 cu=bpy.data.curves.new(n,'FONT');cu.body=body;cu.size=size/1000;cu.align_x='CENTER';o=bpy.data.objects.new(n,cu);col(c).objects.link(o);o.location=tuple(v/1000 for v in p);o.rotation_euler=(math.pi/2,0,math.pi if rear else 0);o.data.materials.append(m);return o
# Main shell: 482 internal width. Front retainer narrows aperture to 476.
for x in [-252.5,252.5]:box('Walnut side stile',(23,104,528),(x,-52,0),wood)
for z in [-252.5,252.5]:box('Walnut cross rail',(482,104,23),(0,-52,z),wood)
for x in [-251,251]:box('Removable front retainer',(26,6,528),(x,-107,0),wood)
for z in [-251,251]:box('Removable front retainer',(476,6,26),(0,-107,z),wood)
# Bottom and top actual ventilation perforations through timber.
for z in [-252.5,252.5]:
 rail=next(o for o in cols['01 Enclosure'].objects if o.name.startswith('Walnut cross rail') and abs(o.location.z-z/1000)<.001)
 for x in range(-190,191,20):
  cutter=box('vent cutter',(9,30,30),(x,-24,z),black,'TEMP',1.5)
  mod=rail.modifiers.new('Open ventilation slot','BOOLEAN');mod.object=cutter;bpy.context.view_layer.objects.active=rail
  bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cutter,do_unlink=True)
# Acrylic layers are included at true size; beauty uses calibrated-looking proxy, not an optical simulation.
box('480 x 480 x 3 opal sheet',(480,3,480),(0,-97,0),opal,'02 Optical stack')
box('480 x 480 x 3 smoked ND sheet',(480,3,480),(0,-101,0),smoke,'02 Optical stack')
for x in [-239.5,239.5]:box('Acrylic edge gasket',(1,7,480),(x,-99,0),black,'02 Optical stack')
# Split support plate into removable rails, leaves cooling and cable passages.
for x in [-220,-100,-60,60,100,220]:box('Panel support rail 3 mm aluminium',(16,3,480),(x,-44,0),silver,'04 Structure')
# Nine board bodies, 64x64 individually modelled emitters per tile in one mesh.
for row in range(3):
 for cc in range(3):
  i=row*3+cc+1;x=(cc-1)*160;z=(1-row)*160
  o=box(f'Tile {i:02} Waveshare 160x160 envelope',(160,14.5,160),(x,-72.75,z),black,'03 Panels',.15);o['source']='Waveshare outline; thickness provisional 14.5 mm, verify received module'
  box(f'Tile {i:02} rear PCB',(154,1.6,154),(x,-64.7,z),pcb,'03 Panels',0)
  for dx in [-60,60]:
   for dz in [-60,60]:
    cyl(f'Tile {i:02} nylon M3 standoff PROVISIONAL hole location',3,20,(x+dx,-55.5,z+dz),nylon,'04 Structure')
    cyl('M3 screw head',2.7,2,(x+dx,-42,z+dz),silver,'04 Structure')
  for dx in [-42,42]:box(f'Tile {i:02} HUB75 IDC socket',(22,9,9),(x+dx,-59,z+15),black,'03 Panels')
  box(f'Tile {i:02} 5V harness connector',(16,10,9),(x,-58,z-25),nylon,'03 Panels')
  text(f'Tile {i} rear label',f'{i:02}  /  64 x 64',(x,-62,z+52),8,white,'03 Panels',True)
verts=[];faces=[]
for row in range(192):
 for cc in range(192):
  x=-240+(cc+.5)*2.5;z=240-(row+.5)*2.5;k=len(verts)
  verts.extend([((x+dx)/1000,-.0802,(z+dz)/1000) for dx,dz in [(-.85,-.85),(.85,-.85),(.85,.85),(-.85,.85)]]);faces.append((k,k+1,k+2,k+3))
me=bpy.data.meshes.new('36864 LED packages mesh');me.from_pydata(verts,[],faces);o=bpy.data.objects.new('36,864 emitters at 2.5 mm pitch',me);col('03 Panels').objects.link(o);o.data.materials.append(nylon)
# Power supply and detail, correct published bounding envelope.
ps=box('Mean Well LRS-350-5 | 215 x 115 x 30',(215,30,115),(-105,-24,-140),silver,'05 Electronics',1);ps['source']='https://www.meanwell.com/Upload/PDF/LRS-350/LRS-350-SPEC.PDF'
for x in range(-194,-20,12):
 for z in range(-181,-97,12):cyl('PSU grille perforation visual',2.2,.3,(x,-8.8,z),black,'05 Electronics')
cyl('PSU cooling fan grille',23,1,(-47,-8,-135),black,'05 Electronics');cyl('PSU fan hub',8,2,(-47,-7,-135),silver,'05 Electronics')
box('PSU terminal guard',(32,20,112),(17,-22,-140),black,'05 Electronics')
for z in range(-184,-95,11):cyl('PSU terminal screw',2.2,2,(18,-10,z),copper,'05 Electronics')
text('PSU legend','LRS-350-5  /  5 V 60 A',(-118,-7,-150),7,black,'05 Electronics',True)
# Pi keep-out plus cooler and bonnet, connector positions visual approximations.
box('Raspberry Pi 5 PCB 85 x 56',(85,1.6,56),(143,-35,100),pcb,'05 Electronics')
for z in [84,104]:box('Pi USB port',(17,15,14),(181,-27,z),silver,'05 Electronics')
box('Pi Ethernet',(21,15,16),(179,-27,122),silver,'05 Electronics')
box('Pi active cooler',(40,10,35),(140,-29,102),silver,'05 Electronics')
cyl('Pi cooler fan',13,1,(144,-23,102),black,'05 Electronics')
box('Triple Matrix Bonnet provisional envelope',(65,1.6,56),(133,-16,100),pcb,'05 Electronics')
for z in [82,100,118]:box('Bonnet HUB75 port',(22,8,9),(128,-11,z),black,'05 Electronics')
box('USB-C power plug separate external 27W feed',(10,7,9),(104,-29,81),black,'05 Electronics')
line('Pi USB-C supply cable reserved exit',[(104,-29,81),(215,-29,81),(225,-20,-245)],black,2)
# Central covered bus pair.
for x,m,lab in [(-25,red,'+5V'),(15,black,'GND')]:
 box(f'RVBOATPAT {lab} base PROVISIONAL 150x20x14',(20,14,150),(x,-24,47),m,'05 Electronics')
 box(f'{lab} tinned bus',(12,2,140),(x,-16,47),copper,'05 Electronics')
 for z in range(-13,108,12):cyl(f'{lab} M4 stud',2,6,(x,-12,z),silver,'05 Electronics')
for i in range(9):
 row=i//3;cc=i%3;x=(cc-1)*160;z=(1-row)*160;zz=-7+i*13
 fx=64;fz=-85+i*27
 box(f'F{i+1:02} inline ATC 10A holder PROVISIONAL',(22,12,17),(fx,-22,fz),black,'06 Harness')
 box(f'F{i+1:02} 10A fuse',(14,3,10),(fx,-14,fz),red,'06 Harness')
 line(f'P{i+1} fused positive',[(-25,-10,zz),(43,-10,zz),(fx,-15,fz),(x+8,-38,z-25),(x+8,-54,z-25)],red,1.7)
 line(f'P{i+1} ground',[(15,-8,zz),(32,-8,zz),(x-8,-40,z-25),(x-8,-54,z-25)],black,1.7)
 text(f'F{i+1} label',f'F{i+1}',(83,-12,fz-2),6,white,'06 Harness',True)
for row in range(3):
 z=(1-row)*160
 line(f'Bonnet port {row+1} ribbon',[(128,-8,82+row*18),(212,-35,z+15),(202,-53,z+15)],ribbon,3)
 for x in [-160,0]:
  for dz in [-3,0,3]:line('IDC row chain',[(x+42,-53,z+15+dz),(x+70,-48,z+15+dz),(x+90,-48,z+15+dz),(x+118,-53,z+15+dz)],ribbon,1)
for z in [-174,-163,-152]:
 line('PSU +V feed reserved route',[(18,-8,z),(38,-8,z),(-25,-9,-20)],red,1.7)
 line('PSU -V feed reserved route',[(18,-7,z+5),(47,-7,z+5),(15,-7,-20)],black,1.7)
box('IEC inlet switch fuse envelope PROVISIONAL',(48,30,28),(-151,-50,-239),black,'05 Electronics')
box('Mains segregation cover PROVISIONAL',(96,34,50),(-145,-23,-216),black,'05 Electronics')
box('VEML7700 ceiling-facing sensor envelope',(18,12,3),(207,-25,245),pcb,'05 Electronics')
# Rear service panel, top cleat and bottom anti-rock pads.
box('Removable rear cover 482 x 482 x 3',(482,3,482),(0,-1.5,0),black,'07 Rear cover')
for x in [-180,180]:
 for z in [-220,220]:cyl('Rear cover captive screw',3,2,(x,1,z),silver,'07 Rear cover')
# Cleat engagement drawn as two opposing sloped profiles, stock product still needs measurement.
def cleat(n,pts):
 vs=[(x/1000,y/1000,z/1000) for x in [-190,190] for y,z in pts];me=bpy.data.meshes.new(n);me.from_pydata(vs,[],[(0,1,2,3),(4,7,6,5),(0,4,5,1),(1,5,6,2),(2,6,7,3),(3,7,4,0)]);o=bpy.data.objects.new(n,me);col('08 Wall mount').objects.link(o);o.data.materials.append(silver)
cleat('Product French cleat PROVISIONAL',[(0,193),(0,220),(10,220),(10,203)])
cleat('Wall French cleat PROVISIONAL',[(12,190),(12,217),(2,207),(2,190)])
for x in [-185,185]:box('Anti-rock rubber pad',(24,12,24),(x,6,-205),black,'08 Wall mount')
# Furniture is separate so the close product view stays uncluttered.
# Display appearance proxy in front of physical acrylic, separate and clearly named.
m=mat('Display proxy | illustrative diffusion',(.01,.01,.01),0,.3);nt=m.node_tree;p=nt.nodes.get('Principled BSDF');im=nt.nodes.new('ShaderNodeTexImage');im.image=bpy.data.images.load(os.path.join(ROOT,'display192.png'));im.interpolation='Closest';nt.links.new(im.outputs['Color'],p.inputs['Base Color']);nt.links.new(im.outputs['Color'],p.inputs['Emission Color']);p.inputs['Emission Strength'].default_value=.75
bpy.ops.mesh.primitive_plane_add(size=.48,location=(0,-.103,0),rotation=(math.pi/2,0,0));o=bpy.context.object;o.name='Illustrative illuminated face - not an optical prediction';o.data.materials.append(m);link(o,'10 Display appearance')
# Dimensions in scene.
def dim(n,a,b,label,txt):
 line(n,[a,b],white,.35,'09 Dimensions')
 for p in [a,b]:line('Dimension tick',[(p[0]-3,p[1],p[2]-3),(p[0]+3,p[1],p[2]+3)],white,.35,'09 Dimensions')
 text(n+' label',label,txt,11)
dim('Overall width',(-264,-117,300),(264,-117,300),'528 mm  /  20.79 in',(0,-117,312))
dim('Overall height',(-300,-117,-264),(-300,-117,264),'528',(-330,-117,0))
dim('Acrylic size',(-240,-118,-295),(240,-118,-295),'480 mm acrylic  /  476 mm visible aperture',(0,-118,-319))
text('Spec header','TESSERA  /  WALNUT WALL CONCEPT',(0,-118,365),14)
text('Spec subtitle','9 x 160 mm panels     192 x 192 pixels     2.5 mm pitch',(0,-118,342),8)
text('Spec footer','110 mm enclosure depth  +  12 mm wall stand-off',(0,-118,-349),9)
# Staging environment is illustrative, no measured room was provided.
box('Room wall',(5000,100,4000),(0,65,300),wallmat,'11 Room',0)
box('Room floor',(5000,4000,50),(0,-1000,-1525),wood,'11 Room',0)
box('Floating credenza',(1150,340,210),(0,-140,-785),wood,'11 Room',5)
for x in [-383,0,383]:box('Credenza doors',(379,8,185),(x,-314,-785),wood,'11 Room',1)
box('Turntable base',(330,270,35),(-240,-150,-661),black,'11 Room',3)
cyl('Turntable platter',115,6,(-240,-150,-640),black,'11 Room','Z')
for x in [-490,490]:
 box('Speaker cabinet',(140,160,220),(x,-170,-570),black,'11 Room',2)
 cyl('Speaker woofer',45,3,(x,-252,-605),black,'11 Room');cyl('Speaker dust cap',21,4,(x,-254,-605),silver,'11 Room')
def camera(n,p,target,lens=55,ortho=None):
 bpy.ops.object.camera_add(location=p);o=bpy.context.object;o.name=n;o.rotation_euler=(Vector(target)-o.location).to_track_quat('-Z','Y').to_euler();o.data.lens=lens
 if ortho:o.data.type='ORTHO';o.data.ortho_scale=ortho
 link(o,'12 Cameras and lights');return o
cams={
 'hero':camera('01 Product portrait',(.82,-1.6,.53),(0,-.04,0),58),
 'room':camera('02 Listening room',(1.5,-3.5,.65),(0,-.1,-.45),52),
 'front_dimensions':camera('03 Dimensioned elevation',(0,-2,0),(0,0,0),ortho=.88),
 'rear_service':camera('04 Rear service',(.76,1.4,.63),(0,-.03,0),58),
 'exploded':camera('05 Exploded assembly',(1.1,-1.7,.75),(0,-.15,0),52)}
def light(n,p,power,size,color):
 bpy.ops.object.light_add(type='AREA',location=p);o=bpy.context.object;o.name=n;o.data.energy=power;o.data.shape='DISK';o.data.size=size;o.data.color=color;o.rotation_euler=(-o.location).to_track_quat('-Z','Y').to_euler();link(o,'12 Cameras and lights')
light('Large warm key',(-1.4,-1.5,2),180,2.0,(1,.85,.68));light('Soft fill',(1,-.4,.4),45,1,(.8,.9,1));light('Rear studio',(0,1.2,1),100,1.5,(1,1,1))
# Facts and explicit uncertainties travel inside the blend.
notes='''TESSERA WALL / CODEX CONCEPT\nUnits: millimetres, geometry in metres.\nCONFIRMED: 9 x 160 mm Waveshare modules, 2.5 mm pitch, 192 square pixels. Two 480 x 480 x 3 acrylic sheets per PARTS.md. LRS-350-5 envelope 215 x 115 x 30 per Mean Well. Pi PCB 85 x 56 per Raspberry Pi.\nDESIGNED: 528 square x 110 deep walnut enclosure; 476 aperture retaining 480 acrylic; 12 wall stand-off; 3 mm support rails; 20 mm nylon standoffs; 15.5 mm LED-to-opal gap.\nPROVISIONAL: panel thickness 14.5, every module mounting-hole centre, sockets, bus bars, bonnet/cooler stack, fuses, IEC cutout, cleat engagement and fastener schedule. Measure purchased parts before fabrication. Support-rail drill patterns must follow actual modules.\nDisplay proxy represents intended appearance, not measured diffuser transmission or brightness. Room and furniture are staging. Wiring curves show topology and reserved routing, not a pinout or fabrication harness. External Pi USB-C supply retained; internal PSU powers panels only. Verify cooler/bonnet compatibility, mains segregation, ventilation and mounting load on physical build.\nSources: docs/WALL-BUILD.md; PARTS.md; https://www.waveshare.com/wiki/RGB-Matrix-P2.5-64x64 ; https://www.meanwell.com/Upload/PDF/LRS-350/LRS-350-SPEC.PDF ; https://datasheets.raspberrypi.com/rpi5/raspberry-pi-5-mechanical-drawing.pdf\n'''
bpy.data.texts.new('READ ME - dimensions and assumptions').write(notes)
open(os.path.join(ROOT,'DESIGN-NOTES.txt'),'w').write(notes)
# Render setup function also used for final saved opening state.
def visibility(names):
 for name,c in cols.items():c.hide_render=name not in names;c.hide_viewport=name not in names
base=['01 Enclosure','02 Optical stack','03 Panels','04 Structure','05 Electronics','06 Harness','07 Rear cover','08 Wall mount','10 Display appearance','12 Cameras and lights']
for name in ['hero','room','front_dimensions','rear_service','exploded']:
 visible=base.copy();moves={}
 if name in ['hero','room']:visible+=['11 Room']
 if name=='front_dimensions':visible+=['09 Dimensions']
 if name=='rear_service':visible=[x for x in base if x not in ['07 Rear cover','10 Display appearance']]
 if name=='exploded':
  visible=[x for x in base if x not in ['10 Display appearance','06 Harness']]
  moves={'02 Optical stack':-.38,'03 Panels':-.18,'01 Enclosure':.16,'07 Rear cover':.20,'08 Wall mount':.24}
 visibility(visible)
 for cn,dy in moves.items():
  for o in cols[cn].objects:o.location.y+=dy
 for o in cols['11 Room'].objects:
  o.hide_render=(name=='hero' and o.name not in ['Room wall','Room floor'])
 s.camera=cams[name];s.render.filepath=os.path.join(ROOT,name+'.png')
 s.render.resolution_x=1800 if name=='room' else 1600;s.render.resolution_y=1400
 bpy.ops.render.render(write_still=True)
 for cn,dy in moves.items():
  for o in cols[cn].objects:o.location.y-=dy
visibility(base+['11 Room']);s.camera=cams['hero']
for screen in bpy.data.screens:
 for a in screen.areas:
  if a.type=='VIEW_3D':a.spaces.active.region_3d.view_perspective='CAMERA'
bpy.ops.file.pack_all();bpy.ops.wm.save_as_mainfile(filepath=os.path.join(ROOT,'tessera-wall-codex.blend'))
print('WALL DESIGN COMPLETE')
