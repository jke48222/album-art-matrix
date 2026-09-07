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
# --- ATELIER / original enclosure geometry, all lengths in mm ---
import xml.etree.ElementTree as ET,zipfile,gzip
from mathutils import Matrix
s.cycles.samples=48;s.render.resolution_x=2200;s.render.resolution_y=1800
s.world.use_nodes=True;s.world.node_tree.nodes['Background'].inputs[0].default_value=(.16,.18,.21,1);s.world.node_tree.nodes['Background'].inputs[1].default_value=.32
bronze=mat('Satin bronze anodised aluminium / proposed finish',(.26,.16,.075),.8,.3)
charcoal=mat('Graphite anodised aluminium / proposed finish',(.027,.031,.033),.78,.32)
softblack=mat('Black silicone and ABS',(.009,.012,.014),0,.6)
glassmat=mat('Cover glass visual shader - transmission uncalibrated',(.009,.013,.015),.18,.16)
ink=mat('Laser marking warm silver',(.55,.53,.47),.4,.43)
red=mat('Silicone wire red',(.35,.009,.012),0,.5)
blue=mat('Blue heat shrink insulation',(.018,.08,.38),0,.4)
# Label every new part as a designed part unless an explicit source is assigned.
def evidence(o,src,status='source dimension / visual reconstruction'):
 o['evidence']=src;o['verification']=status;return o

def rounded(w,h,r,n=12):
 p=[]
 for cx,cz,a in [(w/2-r,h/2-r,0),(-w/2+r,h/2-r,90),(-w/2+r,-h/2+r,180),(w/2-r,-h/2+r,270)]:
  for i in range(n+1):
   t=math.radians(a+i*90/n);p.append((cx+r*math.cos(t),cz+r*math.sin(t)))
 return p

def profile(n,stations,m,c,closed=True):
 # stations = (depth, width, height, corner radius), loft a continuous perimeter.
 vs=[]
 for y,w,h,r in stations:vs += [(x/1000,y/1000,z/1000) for x,z in rounded(w,h,r)]
 L=len(rounded(10,10,1));fs=[]
 for k in range(len(stations)-1):
  for i in range(L):j=(i+1)%L;fs.append((k*L+i,k*L+j,(k+1)*L+j,(k+1)*L+i))
 if closed:
  for i in range(L):j=(i+1)%L;fs.append(((len(stations)-1)*L+i,(len(stations)-1)*L+j,j,i))
 me=bpy.data.meshes.new(n);me.from_pydata(vs,[],fs);me.update();o=bpy.data.objects.new(n,me);col(c).objects.link(o);o.data.materials.append(m)
 for p in me.polygons:p.use_smooth=True
 o.modifiers.new('Weighted surface normals','WEIGHTED_NORMAL');evidence(o,'ATELIER design geometry','proposed new part; not purchased');return o

def ring(n,outer,inner,y,thick,m,c,r=6):return profile(n,[(y,outer,outer,r),(y+thick,outer,outer,r),(y+thick,inner,inner,max(.6,r-(outer-inner)/2)),(y,inner,inner,max(.6,r-(outer-inner)/2))],m,c)

def hole(o,position,r,depth,axis='Y'):
 q=cyl('tool',r,depth,position,black,'TEMP',axis);mod=o.modifiers.new('Through bore','BOOLEAN');mod.object=q;bpy.context.view_layer.objects.active=o;bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(q,do_unlink=True)

def screw(n,p,r=2.75,c='C Carrier'):
 o=cyl(n,r,2,p,silver,c);hole(o,p,1.2,3);return o

def cable(n,pts,m=red,r=1.6,c='H Harness'):
 # Rounded, tangential corners; routing length is only model geometry.
 cu=bpy.data.curves.new(n,'CURVE');cu.dimensions='3D';cu.bevel_depth=r/1000;cu.bevel_resolution=3;cu.resolution_u=12;sp=cu.splines.new('BEZIER');sp.bezier_points.add(len(pts)-1)
 for b,p in zip(sp.bezier_points,pts):b.co=tuple(v/1000 for v in p);b.handle_left_type='AUTO';b.handle_right_type='AUTO'
 o=bpy.data.objects.new(n,cu);col(c).objects.link(o);o.data.materials.append(m);o['verification']='designed route, not as-built harness';return o
# Continuous sculpted shell. Thin front edge, broad rear bevel.
profile('A01 Sculpted enclosure / 536 square / 116 deep',[
 (-116,536,536,12),(-112,536,536,12),(-94,532,532,12),(-23,498,498,10),(0,492,492,9),
 (0,484,484,5),(-23,490,490,6),(-94,510,510,5),(-116,510,510,5)],charcoal,'A Exterior')
ring('A02 Bronze perimeter 1.2 mm face reveal',536,533.6,-116.15,1.2,bronze,'A Exterior',12)
ring('A03 Bronze optical bezel',511,508,-113.5,2,bronze,'A Exterior',5)
# Recessed side inlay follows the sculpted shoulder, rather than decorating the front.
profile('A04 Fine bronze shoulder line',[(-94,532.5,532.5,12),(-92.8,532,532,12),(-92.8,531.3,531.3,11.5),(-94,531.8,531.8,11.5)],bronze,'A Exterior')
# Two vent fields in rear, open through cover with fine grille bars; intentionally no front vent slots.
cover=box('R01 Removable aluminium service cover',(484,2,484),(0,-1,0),charcoal,'R Rear cover',3)
for zz in [-216,216]:
 q=box('vent tool',(340,5,22),(0,-1,zz),black,'TEMP',3);mod=cover.modifiers.new('Rear intake / outlet opening','BOOLEAN');mod.object=q;bpy.context.view_layer.objects.active=cover;bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(q,do_unlink=True)
 for xx in range(-165,166,5):box('Rear vent guard',(1.3,1.3,22),(xx,-1,zz),charcoal,'R Rear cover',.35)
for x in [-228,228]:
 for z in [-228,0,228]:screw('Rear M3 captive cover screw',(x,.8,z),2.75,'R Rear cover')
# A continuous recessed ventilation clearance is achieved by a designed 16mm wall spacer frame.
for x in [-170,170]:box('Cleat spacer / proposed 16mm wall plenum',(36,16,35),(x,8,159),charcoal,'M Mount',1)
for x in [-185,185]:box('Bottom anti-rock spacer',(24,19,24),(x,9.5,-183),softblack,'M Mount',2)
# Optical cassette, specified geometry; actual optical grade/tint remains a sample decision.
box('O01 Proposed cover glass 508 x 508 x 3',(508,3,508),(0,-110.5,0),glassmat,'O Optics',.7)
ring('O02 Mechanical cassette gasket',510,496,-109,1.5,softblack,'O Optics',5)
ring('O03 Black perimeter mask / full 480 aperture',506,480,-112.05,.1,black,'O Optics',4)
box('O04 Removable 494 x 494 x 2 diffuser candidate',(494,2,494),(0,-104,0),opal,'O Diffuser',.3)
# Four clamp bars retain the front glass mechanically; eight accessible screws are behind the fascia.
for axis in [0,1]:
 for sg in [-1,1]:
  d=(8,3,494) if axis==0 else (494,3,8);p=(sg*250,-106,0) if axis==0 else (0,-106,sg*250)
  box('Cassette rear clamp',d,p,charcoal,'C Carrier',.5)
# Front cassette mark sits on non-emissive border.
text('Tessera signature','t e s s e r a',(0,-112.22,-247),4,ink,'A Exterior')
# Source rear shell is 159.8 +/-0.1 wide, 12 deep. Eight M3 bosses from DWG.
PANEL_SRC='Waveshare RGB-Matrix-P2_5-64x64-2D.dwg, official GitHub hardware/dimensions'
mounts=[(-45,-73),(45,-73),(-73,-45),(73,-45),(-73,45),(73,45),(-45,73),(45,73)]
for rr in range(3):
 for cc in range(3):
  i=rr*3+cc+1;x=(cc-1)*160;z=(1-rr)*160
  o=box(f'P{i:02} nominal panel PCB face 160 square',(160,.8,160),(x,-94.6,z),pcb,'P Panels',.1);evidence(o,PANEL_SRC,'nominal panel outline; PCB thickness follows drawing side detail')
  # Actual open ribbed rear shell; no fictional solid 14.5mm brick.
  for dx in [-78.9,78.9]:evidence(box(f'P{i:02} rear shell side rib',(2,12,159.8),(x+dx,-88,z),softblack,'P Panels',.3),PANEL_SRC)
  for dz in [-78.9,78.9,-30,30]:evidence(box(f'P{i:02} rear shell cross rib',(155.8,12,2),(x,-88,z+dz),softblack,'P Panels',.3),PANEL_SRC)
  for dx in [-30,30]:box(f'P{i:02} vertical stiffener',(2,12,155.8),(x+dx,-88,z),softblack,'P Panels',.3)
  for dx,dz in mounts:
   o=cyl(f'P{i:02} M3 boss',3.7,12,(x+dx,-88,z+dz),softblack,'P Panels');hole(o,(x+dx,-88,z+dz),1.5,14);evidence(o,PANEL_SRC,'M3 coordinates from drawing; boss outer diameter visual')
  # Four chosen, source-matched mounting sites with nylon stand-off and carrier tabs.
  for dx,dz in [(-45,-73),(45,-73),(-45,73),(45,73)]:
   cyl(f'P{i:02} M3 nylon standoff proposed 20mm',3,20,(x+dx,-72,z+dz),nylon,'C Carrier')
   box(f'P{i:02} support tab',(15,3,12),(x+dx,-60.5,z+dz),charcoal,'C Carrier')
   screw(f'P{i:02} mounting screw',(x+dx,-58,z+dz),2.75,'C Carrier')
  text(f'P{i:02} ID',f'{i:02}',(x,-81.8,z+67),5,ink,'P Panels',True)
# Full carrier uses row beams at confirmed top/bottom boss z coordinates.
for z in [-233,-87,-73,73,87,233]:box('Carrier crossbeam / grounded chassis',(482,3,12),(0,-60.5,z),charcoal,'C Carrier',.5)
for x in [-238,238]:box('Carrier side beam',(10,3,478),(x,-60.5,0),charcoal,'C Carrier',.5)
# Explicit unresolved footprints: movable routing pads, no invented connector-cutout drawing.
for row in range(3):
 for cc in range(3):
  i=row*3+cc+1;x=(cc-1)*160;z=(1-row)*160
  # DIN-style open pin headers recreated to HUB75 pitch; actual socket centers await module photo.
  for dx in [-45,45]:
   b=box(f'P{i:02} HUB75 position pending photo',(23,6,9),(x+dx,-83,z),softblack,'U Unresolved fit',.3);b['verification']='connector placement unresolved; not used for drill pattern'
  box(f'P{i:02} power landing pending photo',(16,7,10),(x,-83,z-43),nylon,'U Unresolved fit',.3)
# LED packages 2.1 square in plan based on drawing specifying 2121; front emission is at y=-95.
verts=[];faces=[]
for r in range(192):
 for c in range(192):
  x=-240+(c+.5)*2.5;z=240-(r+.5)*2.5;k=len(verts)
  verts += [((x+dx)/1000,-.095,(z+dz)/1000) for dx,dz in [(-1.05,-1.05),(1.05,-1.05),(1.05,1.05),(-1.05,1.05)]];faces.append((k,k+1,k+2,k+3))
me=bpy.data.meshes.new('192x192 physical emitter faces');me.from_pydata(verts,[],faces);o=bpy.data.objects.new('36,864 physical emitters / 2.5mm centres',me);col('P Panels').objects.link(o);o.data.materials.append(black)
# True scale Mean Well enclosure, pierced face follows official mechanical drawing.
PSU_SRC='https://www.meanwell.com/Upload/PDF/LRS-350/LRS-350-SPEC.PDF'
px,pz=-98,-158
body=box('E01 LRS-350-5 base',(215,1.2,115),(px,-55.4,pz),silver,'E Power',.7);evidence(body,PSU_SRC,'215x115x30 manufacturer envelope, +/-1mm')
for zz in [-56.9,56.9]:box('PSU folded wall',(215,28.8,1.2),(px,-40.4,pz+zz),silver,'E Power',.4)
box('PSU closed end',(1.2,28.8,112.6),(px+106.9,-40.4,pz),silver,'E Power',.4)
top=box('PSU punched steel cover',(203,1.0,112.6),(px+6,-25.5,pz),silver,'E Power',.3)
# Real curved fan grille with annular slots.
fanx=px+107.5-47.45;fanz=pz+57.5-36.7
for rad in [15,23]:
 for q in range(4):
  pts=[]
  for j in range(17):
   t=math.radians(q*90+10+j*70/16);pts.append((fanx+rad*math.cos(t),-25.5,fanz+rad*math.sin(t)))
  cut=line('Fan aperture cutter',pts,black,2.8,'TEMP');bpy.context.view_layer.objects.active=cut;cut.select_set(True);bpy.ops.object.convert(target='MESH');mod=top.modifiers.new('Fan arc slot','BOOLEAN');mod.object=cut;bpy.context.view_layer.objects.active=top;bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cut,do_unlink=True)
cyl('PSU fan dark rotor',25,8,(fanx,-32,fanz),softblack,'E Power');cyl('PSU fan centre',6,9,(fanx,-31.5,fanz),silver,'E Power')
for xx in [px-69,px-43]:
 for zz in [-18,0,18]:
  tool=box('vent cutter',(18,4,3),(xx,-25.5,pz+zz),black,'TEMP',1.4);mod=top.modifiers.new('PSU straight ventilation','BOOLEAN');mod.object=tool;bpy.context.view_layer.objects.active=top;bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(tool,do_unlink=True)
# Terminal strip and barrier wells. Drawing establishes terminal order, pitch 9.5.
box('PSU 9 way terminal strip',(15,12,89),(px-101,-39,pz),softblack,'E Power',.4)
for j in range(9):
 zz=pz-38+j*9.5;box('PSU terminal barrier',(16,13,1.1),(px-101,-38.5,zz-4.75),softblack,'E Power',.1);screw('PSU screw',(px-101,-32,zz),2.7,'E Power')
text('PSU marking','MEAN WELL  /  LRS-350-5',(px+0,-24.8,pz-40),5,black,'E Power',True)
text('PSU rating','5 V  /  60 A  /  300 W',(px+0,-24.8,pz-48),3.4,black,'E Power',True)
# Slot-mounted PSU carrier, no unsupported wall load through front glass.
for xx in [px-75,px+75]:
 for zz in [pz-67.5,pz+67.5]:box('PSU mounting tab',(16,3,15),(xx,-55,zz),silver,'E Power',1)
# Actual RVBOATPAT silhouette and double rows; dimensions from exact listing image.
BUS_SRC='https://www.amazon.com/dp/B0CF1N8FM8 product size image 2'
for bz,m,label in [(51,red,'+5V'),(9,softblack,'GND')]:
 bx=-73
 o=box(f'E02 RVBOATPAT {label} rounded base',(137.16,5,22.86),(bx,-48.5,bz),m,'E Bus bars',10);evidence(o,BUS_SRC,'5.4in envelope; 4.7in mount span; double row terminals')
 box(f'{label} metal bus',(96.52,3,18),(bx,-44.5,bz),silver,'E Bus bars',.4)
 for j in range(6):
  for dz in [-5.08,5.08]:screw(f'{label} M4 terminal',(bx-35+j*10.16,-41,bz+dz),3.1,'E Bus bars')
 cyl(f'{label} quarter-inch stud',3.175,14,(bx+45,-35,bz),silver,'E Bus bars')
 for dx in [-59.69,59.69]:hole(o,(bx+dx,-48.5,bz),2.4,7)
 # Actual opaque guard is removable and separate, shown raised in component detail.
 box(f'{label} protective cover',(96,8,23),(bx-8,-32,bz),m,'K Bus covers',2)
# Nilight bodies cannot be dimension-certified from published 5x1x3in shipping envelope.
# Design nine individual saddle positions and detachable cable combs; retained bodies shown as unverified photo forms.
for i in range(9):
 fx=60+(i%3)*48;fz=22-(i//3)*42
 box(f'F{i+1:02} proposed removable fuse saddle',(38,2,29),(fx,-49,fz),charcoal,'H Harness',2)
 o=box(f'F{i+1:02} Nilight PHOTO FORM - body dimensions pending',(27,13,20),(fx,-40,fz),softblack,'U Unresolved fit',2);o['verification']='photo form only, not verified dimensions; saddle release blocked on measurement'
 for zz in range(-6,7,3):box('Fuse lid texture',(21,.4,.65),(fx,-32.8,fz+zz),black,'U Unresolved fit',.1)
 text(f'F{i+1:02} legend',f'{i+1:02}   10A',(fx,-31.9,fz),3,ink,'U Unresolved fit',True)
 cable('Fuse tether',[(fx+12,-38,fz),(fx+20,-36,fz+8),(fx+12,-33,fz+10)],softblack,.8,'U Unresolved fit')
# Braided-looking trunk routes and labelled drops, reserved outside mains compartment.
for i in range(9):
 rr=i//3;cc=i%3;pxx=(cc-1)*160;pzz=(1-rr)*160;fx=60+cc*48;fz=22-rr*42
 cable(f'F{i+1:02} positive input',[(-108+(i%6)*10.16,-39,56.08),(18,-39,68-i*3),(fx,-39,fz+12)],red,1.6)
 cable(f'F{i+1:02} fused panel drop',[(fx,-40,fz-12),(198+cc*5,-46,fz-18),(pxx+20,-70,pzz-55),(pxx+5,-79,pzz-43)],red,1.6)
 cable(f'P{i+1:02} negative return',[(-108+(i%6)*10.16,-39,14.08),(22,-43,75-i*3),(pxx-20,-73,pzz-55),(pxx-5,-79,pzz-43)],softblack,1.6)
 for zz in [fz+17,fz-17]:cyl('Blue butt splice',3,14,(fx,-41,zz),blue,'H Harness','Z')
# Manufacturer 3MF import, keeping individual geometry/materials and no rescaling.
def import_3mf(path,origin,cn):
 ns={'c':'http://schemas.microsoft.com/3dmanufacturing/core/2015/02','m':'http://schemas.microsoft.com/3dmanufacturing/material/2015/02'}
 root=ET.fromstring(zipfile.ZipFile(path).read('3D/3dmodel.model'));colors={}
 for cg in root.findall('c:resources/m:colorgroup',ns):
  mm=[]
  for q in cg:
   h=q.attrib['color'].lstrip('#');rgb=[int(h[i:i+2],16)/255 for i in [0,2,4]];rgb=[v/12.92 if v<.04045 else ((v+.055)/1.055)**2.4 for v in rgb];mm.append(mat('Adafruit original CAD colour '+h,rgb,.3 if max(rgb)-min(rgb)<.1 else 0,.4))
  colors[cg.attrib['id']]=mm
 objects=[]
 for el in root.findall('c:resources/c:object',ns):
  vs=[(float(v.attrib['x']),float(v.attrib['y']),float(v.attrib['z'])) for v in el.findall('c:mesh/c:vertices/c:vertex',ns)];fs=[tuple(int(q.attrib[k]) for k in ['v1','v2','v3']) for q in el.findall('c:mesh/c:triangles/c:triangle',ns)]
  # x -> x, y -> z, z -> rear depth. Flip triangle winding for handedness.
  verts=[((v[0]+origin[0])/1000,(v[2]+origin[1])/1000,(v[1]+origin[2])/1000) for v in vs]
  me=bpy.data.meshes.new(el.attrib['name']);me.from_pydata(verts,[],[f[::-1] for f in fs]);o=bpy.data.objects.new('Adafruit 6358 | '+el.attrib['name'],me);col(cn).objects.link(o)
  mats=colors.get(el.attrib.get('pid'),[black])
  for m in mats:o.data.materials.append(m)
  for poly,tr in zip(me.polygons,el.findall('c:mesh/c:triangles/c:triangle',ns)):poly.material_index=int(tr.attrib.get('p1',el.attrib.get('pindex','0')))
  evidence(o,'Adafruit_CAD_Parts/6358 Triple LED Matrix Bonnet.3mf','official manufacturer CAD, mm units, geometry unscaled');objects.append(o)
 return objects
# Controller bay. Official Pi mesh is imported below; exposed GPIO faces establish mating datums.
PI_ORIGIN=(88,-55,118)
pi_parts=json.load(open(os.path.join(ROOT,'references/pi-meshes.json')))
# CAD coordinates are retained except rigid orientation/translation, recorded in object metadata.
# Determine PCB solid using its thin, wide envelope.
boardpart=max((q for q in pi_parts if q['bounds'][1]-q['bounds'][0]>80 and q['bounds'][3]-q['bounds'][2]>50),key=lambda q:len(q['vertices']))
B=boardpart['bounds'];cx=(B[0]+B[1])/2;cy=(B[2]+B[3])/2;pcbtop=B[5]
for q in pi_parts:
 b=q['bounds'];dx=b[1]-b[0];dy=b[3]-b[2];dz=b[5]-b[4]
 ma=pcb if dx>80 and dy>50 else (silver if max(dx,dy)>12 and dz>3 else (copper if dz>4 and dx<1 and dy<1 else black))
 vs=[((v[0]-cx+PI_ORIGIN[0])/1000,(v[2]-B[4]+PI_ORIGIN[1])/1000,(v[1]-cy+PI_ORIGIN[2])/1000) for v in q['vertices']]
 me=bpy.data.meshes.new('Raspberry Pi solid');me.from_pydata(vs,[],[f[::-1] for f in q['faces']]);o=bpy.data.objects.new(f'Official Raspberry Pi 5 CAD solid {q["id"]}',me);col('D Controller').objects.link(o);o.data.materials.append(ma);evidence(o,'Raspberry Pi RP-010083-CA-1 rpi-5b_no_graphics.step','official geometry, material classification for visualization only')
# Pi nominal top pin header housing = 2.5 mm on 1.6 mm board from source model/drawing.
# Frienda source figure 51x5x23; description exposed pin length12 => body nominal11.
# Through-style bonnet socket body height5.54 from its manufacturer CAD.
header_part=next(q for q in pi_parts if q['id']==1341)
riser_base=PI_ORIGIN[1]+header_part['bounds'][5]-B[4]
riser_top=riser_base+11
bx=PI_ORIGIN[0]-42.5+7;gz=PI_ORIGIN[2]-28+52.5
ris=box('Frienda 40-pin riser fully seated / nominal 51x5x11 body',(51,11,5),(bx+25.5,riser_base+5.5,gz),softblack,'D Controller',.25);evidence(ris,'B084Q4W1PW dimension image: 51x5x23; listing 12mm pin length','nominal derived body11; fully seated per user; verify tolerances physically')
for j in range(20):
 for dz in [-1.27,1.27]:box('Frienda 12mm pass-through pin',(.6,12,.6),(bx+1.37+j*2.54,riser_top+6,gz+dz),copper,'D Controller',.06)
# Bonnet GPIO is near rear long edge at y=27.2, its underside lowest datum -5.54.
bonnet_board_y=riser_top+5.54
bonnet=import_3mf(os.path.join(ROOT,'references/6358 Triple LED Matrix Bonnet.3mf'),(bx-7,bonnet_board_y,gz-26.49),'D Controller')
# Cooler: published 63.5x42.5x13.7 envelope; fin pattern follows product drawing, not thermal model.
ccx=PI_ORIGIN[0]-8;ccz=PI_ORIGIN[2]-3
cool=box('Raspberry Pi Active Cooler nominal base',(63.5,2,42.5),(ccx,-51,ccz),silver,'D Controller',1);evidence(cool,'Raspberry Pi Active Cooler product brief p5','reference envelope; fin geometry reconstructed')
for xx in range(-26,-4,3):
 for zz in range(-16,17,5):box('Cooler fin',(1,7,3),(ccx+xx,-46.5,ccz+zz),silver,'D Controller',.2)
box('Active Cooler blower 30mm',(30,8,30),(ccx+11,-46,ccz+4),silver,'D Controller',3)
cyl('Active Cooler blower intake',10.5,.7,(ccx+11,-41.5,ccz+4),black,'D Controller')
for a in range(0,360,45):
 t=math.radians(a);line('Blower vanes',[(ccx+11+4*math.cos(t),-41.05,ccz+4+4*math.sin(t)),(ccx+11+9*math.cos(t+.3),-41.05,ccz+4+9*math.sin(t+.3))],silver,.6,'D Controller')
# Microphone exact published exterior dimensions, remote USB lead proposed to bottom acoustic inlet.
mic=box('Adafruit 3367 USB microphone / 22.2x18.3x7',(18.3,7,22.2),(190,-45,-182),softblack,'S Sensors',3);evidence(mic,'https://www.adafruit.com/product/3367','published dimensions; surface detailing reconstructed')
for x in [-4,0,4]:
 for z in [-4,0,4]:cyl('Microphone aperture',.5,.4,(190+x,-41.3,-182+z),black,'S Sensors')
cable('Proposed microphone USB extension',[(190,-45,-170),(210,-50,55),(135,-48,125)],softblack,2)
# Lux sensor at top faces ceiling, published PCB1.0x0.7in and mounting pitch0.8x0.5.
lux=box('Adafruit 4162 QT sensor 25.4x17.78 PCB',(25.4,17.78,1.6),(192,-31,234),pcb,'S Sensors',1);evidence(lux,'Adafruit VEML7700Q fab print, dimensions in inches','PCB outline and hole pitch verified; small component volumes illustrative')
for dx in [-10.16,10.16]:
 for dy in [-6.35,6.35]:hole(lux,(192+dx,-31+dy,234),1.3,3,'Z')
box('VEML7700 optical package',(6.8,2.35,3),(192,-31,236),silver,'S Sensors',.3)
# Switched IEC module in a service pod, not on the front facade. Exterior dimensions verified; cutout pending.
ibox=box('Antrader C14 module 50x30x30 envelope',(30,30,50),(-210,-29,-140),softblack,'E Power',1);evidence(ibox,'https://www.amazon.com/dp/B081VD1NNT','seller overall 50x30x30; snap-fit cutout is not specified')
box('IEC red rocker',(19,2,13),(-210,-13,-124),red,'E Power',1)
box('IEC fuse drawer',(21,2,9),(-210,-13,-137),black,'E Power',.5)
box('IEC C14 socket cavity',(21,2,18),(-210,-13,-153),black,'E Power',2)
for dx,dz in [(-6,-3),(6,-3),(0,4)]:box('IEC male contact',(2,4,4),(-210+dx,-11,-153+dz),silver,'E Power',.15)
# Separate removable mains guard encloses inlet terminal zone and NTC. This is a design envelope, not a certification.
box('Mains service guard',(56,31,96),(-209,-30,-150),charcoal,'G Mains guard',2)
nt=cyl('SL2210005 NTC 22mm disc',11,5,(-200,-37,-204),black,'E Power');evidence(nt,'https://www.ametherm.com/datasheetspdf/SL2210005.pdf','manufacturer maximum diameter22, maximum thickness5; nominal lead pitch7.8')
# Data ribbons: 16 parallel conductors, restrained in separated routes, endpoints pending PCB photo.
for row in range(3):
 z=(1-row)*160
 for cc in range(2):
  xx=(cc-1)*160
  for k in range(16):cable(f'Row {row+1} IDC conductor {k}',[(xx+45,-78,z+(k-7.5)*1.27),(xx+72,-68,z+(k-7.5)*1.27),(xx+95,-68,z+(k-7.5)*1.27),(xx+115,-78,z+(k-7.5)*1.27)],red if k==0 else ribbon,.42)
 for k in range(16):cable(f'Bonnet port {row+1} IDC conductor {k}',[(100,-16,130+(k-7.5)*1.27),(225,-42,130+(k-7.5)*1.27),(205,-65,z+(k-7.5)*1.27)],red if k==0 else ribbon,.42)
# OOK reference length304.8 and mounting pitch25.4; installed projection3.175 from listing.
for wallside in [False,True]:
 y=16 if not wallside else 19.175
 o=box('OOK 533208 '+('wall' if wallside else 'product')+' cleat 12in',(304.8,1.3,25),(0,y,164),silver,'M Mount',.3);evidence(o,'B005PUC4KE images3,5','length304.8, hole pitch25.4, installed projection3.175; profile height photo-reconstructed')
 for xx in [i*25.4 for i in range(-5,6)]:hole(o,(xx,y,168 if not wallside else 160),2,4)
 profile('OOK engaging angled lip',[(y,304.8,10,.3),(y+1,304.8,10,.3)],silver,'TEMP',False).hide_render=True
# Modern rear nameplate, no certification or unsupported rating marks.
box('Rear identity plate',(92,1,29),(155,1,187),black,'R Rear cover',1)
text('Rear identity','T E S S E R A',(155,1.6,188),5,ink,'R Rear cover',True)
text('Rear serial','ATELIER  /  DESIGN STUDY 02',(155,1.6,180),2.6,ink,'R Rear cover',True)
# Appearance layer: real project album rendered to 192 square, explicitly not optical prediction.
def screen_mat(file):
 m=mat('192px emissive display appearance '+file,(.01,.01,.01),0,.28);nt=m.node_tree;p=nt.nodes.get('Principled BSDF');im=nt.nodes.new('ShaderNodeTexImage');im.image=bpy.data.images.load(os.path.join(ROOT,file));im.interpolation='Closest';nt.links.new(im.outputs['Color'],p.inputs['Base Color']);nt.links.new(im.outputs['Color'],p.inputs['Emission Color']);p.inputs['Emission Strength'].default_value=.6;return m
album=screen_mat('album192.png');disc=screen_mat('disc192.png')
bpy.ops.mesh.primitive_plane_add(size=.480,location=(0,-.11212,0),rotation=(math.pi/2,0,0));screen=bpy.context.object;screen.name='192px optical appearance proxy / not measured';screen.data.materials.append(disc);link(screen,'V Display appearance');screen['verification']='visual target; not measured optical transmission or LED luminance'
# Room staging: textured plaster, dark figured timber and monolithic stone shelf.
plaster=mat('Warm limestone plaster',(.31,.29,.25),0,.9);stone=mat('Honed travertine',(.23,.21,.175),0,.72)
for m,scale,strength in [(plaster,160,.12),(stone,60,.18)]:
 nt=m.node_tree;n=nt.nodes.new('ShaderNodeTexNoise');n.inputs['Scale'].default_value=scale;n.inputs['Detail'].default_value=3;b=nt.nodes.new('ShaderNodeBump');b.inputs['Strength'].default_value=strength;b.inputs['Distance'].default_value=.001;nt.links.new(n.outputs['Fac'],b.inputs['Height']);nt.links.new(b.outputs[0],nt.nodes['Principled BSDF'].inputs['Normal'])
box('Gallery plaster wall',(6000,100,4300),(0,70,150),plaster,'Z Room',0)
box('Stone ledge',(1300,380,85),(0,-140,-690),stone,'Z Furniture',3)
box('Smoked oak console',(1240,320,210),(0,-108,-836),wood,'Z Furniture',2)
for x in range(-600,601,12):box('Console fine fluting',(2,3,195),(x,-270,-836),softblack,'Z Furniture',.3)
# Record player is an original staging object, no brand association.
box('Turntable plinth',(330,250,28),(-200,-145,-632),charcoal,'Z Furniture',5)
cyl('Turntable vinyl',112,5,(-220,-145,-615),black,'Z Furniture','Z');cyl('Record paper label',32,.2,(-220,-145,-612.3),bronze,'Z Furniture','Z')
cable('Turntable arm',[(-65,-84,-609),(-77,-123,-597),(-100,-174,-596)],silver,2.2,'Z Furniture')
for x in [-500,500]:
 box('Staging compact speaker',(135,150,220),(x,-155,-537),charcoal,'Z Furniture',9)
 cyl('Speaker fabric inset',46,1,(x,-231,-575),softblack,'Z Furniture');cyl('Speaker tweeter',16,1,(x,-231,-497),softblack,'Z Furniture')
# Camera, lighting and dimensions.
def camera(n,p,t,lens=60,ortho=None):
 bpy.ops.object.camera_add(location=p);o=bpy.context.object;o.name=n;o.rotation_euler=(Vector(t)-o.location).to_track_quat('-Z','Y').to_euler();o.data.lens=lens
 if ortho:o.data.type='ORTHO';o.data.ortho_scale=ortho
 link(o,'Z Studio');return o
cams={
 '01-hero':camera('01 Atelier portrait',(.79,-1.5,.32),(0,-.04,0),62),
 '02-listening-room':camera('02 Listening room',(1.22,-3.35,.38),(0,-.06,-.37),57),
 '03-corner-detail':camera('03 Bronze and glass detail',(.48,-.70,.28),(.17,-.09,.17),85),
 '04-rear-service':camera('04 Open rear service',(.43,1.33,.41),(0,-.04,0),62),
 '05-exploded':camera('05 Exploded assembly',(1.12,-1.65,.7),(0,-.20,0),48),
 '06-dimensions':camera('06 Dimension elevation',(0,-2,0),(0,0,0),ortho=1.08),
 '07-controller':camera('07 Actual controller hardware',(.28,.30,.30),(.09,-.028,.12),72),
 '08-album-mode':camera('08 Album artwork portrait',(.68,-1.6,.18),(0,-.04,0),65)}
def light(n,p,t,power,size,color,shape='DISK',size_y=None):
 bpy.ops.object.light_add(type='AREA',location=p);o=bpy.context.object;o.name=n;o.data.energy=power;o.data.shape=shape;o.data.size=size
 if size_y:o.data.size_y=size_y
 o.data.color=color;o.rotation_euler=(Vector(t)-o.location).to_track_quat('-Z','Y').to_euler();link(o,'Z Studio')
light('Soft gallery window',(-1.1,-1.6,1.6),(0,0,0),125,1.7,(1,.85,.68),'RECTANGLE',1.1)
light('Long bronze edge strip',(.7,-.5,1.3),(0,0,0),50,.12,(1,.83,.57),'RECTANGLE',1.5)
light('Cool low fill',(-.9,-.4,-.5),(0,0,0),15,.8,(.68,.79,1))
light('Rear technical softbox',(0,1.2,.9),(0,-.05,0),90,1.4,(1,.95,.86))
# Drawing annotations only in dedicated view, all explicitly design dimensions.
def dimension(a,b,label,tp):
 line('Dimension',[a,b],ink,.25,'Q Dimensions')
 for p in [a,b]:line('Tick',[(p[0]-3,p[1],p[2]-3),(p[0]+3,p[1],p[2]+3)],ink,.25,'Q Dimensions')
 text('Dimension value',label,tp,9,ink,'Q Dimensions')
dimension((-268,-119,303),(268,-119,303),'536 mm  /  designed enclosure',(0,-119,313))
dimension((-240,-119,-305),(240,-119,-305),'480 mm  /  full active aperture',(0,-119,-329))
dimension((-305,-119,-268),(-305,-119,268),'536',(-332,-119,0))
text('Title','T E S S E R A   /   A T E L I E R',(0,-119,368),13,ink,'Q Dimensions')
text('Subtitle','GRAPHITE ALUMINIUM     /     SATIN BRONZE     /     REMOVABLE OPTICS',(0,-119,344),6,ink,'Q Dimensions')
text('Footnote','116 mm body depth  +  19.175 mm nominal mounting projection',(0,-119,-354),7,ink,'Q Dimensions')
text('Status','DESIGN STUDY 02  /  SOURCE GEOMETRY + PROPOSED ENCLOSURE  /  NOT A FABRICATION RELEASE',(0,-119,-376),5,ink,'Q Dimensions')
# Every model object can be inspected for evidence; unverified objects are separate.
for o in s.objects:
 if 'verification' not in o:o['verification']='proposed design detail or visual detailing; not a measured purchased component'
# Save assembly before render so interruption never loses work.
notes=open(os.path.join(ROOT,'MODEL-NOTES.txt')).read() if os.path.exists(os.path.join(ROOT,'MODEL-NOTES.txt')) else 'Design study. Physical optics, cooling, final wiring and seated stack tolerances require validation.'
bpy.data.texts.new('READ FIRST - verification and design decisions').write(notes)
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
