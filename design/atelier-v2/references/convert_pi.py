import cadquery as cq,json,pathlib,time
R=pathlib.Path(__file__).parent
print('Loading official Raspberry Pi STEP',flush=True)
s=cq.importers.importStep(str(R/'raspberry-pi-5.step')).val();solids=s.Solids();print('Solids',len(solids),'bounds',s.BoundingBox(),flush=True)
out=[]
for i,q in enumerate(solids):
 v,f=q.tessellate(.08,.2);bb=q.BoundingBox();out.append({'id':i,'vertices':[a.toTuple() for a in v],'faces':f,'bounds':[bb.xmin,bb.xmax,bb.ymin,bb.ymax,bb.zmin,bb.zmax]})
(R/'pi-meshes.json').write_text(json.dumps(out,separators=(',',':')))
print('DONE',len(out),flush=True)
