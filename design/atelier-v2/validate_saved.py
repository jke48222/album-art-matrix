import bpy, os, json
from mathutils import Vector
ROOT=os.path.dirname(os.path.abspath(__file__))
bpy.ops.wm.open_mainfile(filepath=os.path.join(ROOT,'Tessera-Atelier.blend'))
s=bpy.context.scene

def bounds(objects):
 vs=[o.matrix_world@Vector(v) for o in objects for v in o.bound_box]
 return [[min(v[i] for v in vs)*1000,max(v[i] for v in vs)*1000] for i in range(3)]
pi=[o for o in s.objects if o.name.startswith('Official Raspberry Pi 5 CAD solid')]
bonnet=[o for o in s.objects if o.name.startswith('Adafruit 6358 |')]
riser=next(o for o in s.objects if o.name.startswith('Frienda 40-pin riser fully seated'))
header=bpy.data.objects['Official Raspberry Pi 5 CAD solid 1341']
rb=bounds([riser]);hb=bounds([header]);bb=bounds(bonnet)
report={'objects':len(s.objects),'pi_solids':len(pi),'bonnet_meshes':len(bonnet),'cameras':len([o for o in s.objects if o.type=='CAMERA']),'riser_to_pi_mating_gap_mm':rb[1][0]-hb[1][1],'bonnet_to_riser_mating_gap_mm':bb[1][0]-rb[1][1],'nominal_bonnet_top_above_pi_pcb_bottom_mm':bb[1][1]+55,'packed_images':[im.name for im in bpy.data.images if im.packed_file],'notes_embedded':len(bpy.data.texts['READ FIRST - verification and design decisions'].as_string())>3000,'restored_camera':s.camera.name}
assert len(pi)==2689 and len(bonnet)==138
assert abs(report['riser_to_pi_mating_gap_mm'])<.001
assert abs(report['bonnet_to_riser_mating_gap_mm'])<.001
assert report['notes_embedded']
assert s.camera.name.startswith('01 ')
with open(os.path.join(ROOT,'validation.json'),'w') as f:json.dump(report,f,indent=2)
print(json.dumps(report,indent=2))
