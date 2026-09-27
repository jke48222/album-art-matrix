"""Authored, credential-free setup screen states."""
import io
import time
from device_services_fixtures import configure as devices

# The brain's own answer when it was built without Show me (control.py, GET /services).
OFF = {'key_set':False,'cx_set':False,'pictures':0,'last':None,'state':'off','verified':False,'checking':False,'checked_at':None,'problem':'Show me is off on this wall.'}

def last_picture_png(side=64):
    """The frame a found picture leaves on the wall, as GET /pictures/last.png serves it.

    The authored artwork, enlarged like a downloaded picture, goes through the
    same square framing the brain uses (prepare at the wall's side), so the
    phone's square is what the panel would have shown.
    """
    from PIL import Image
    from brain.art.pipeline import prepare
    from capture_home import artwork
    source=Image.frombytes('RGB',(512,512),artwork(512))
    stream=io.BytesIO();prepare(source,side).save(stream,format='PNG')
    return stream.getvalue()

def configure(wall,phase='ready',host=''):
    data=devices(wall,'connected',host)
    google={'key_set':False,'cx_set':False,'pictures':0,'last':None,'state':'default','verified':False,'checking':False,'problem':None}
    if phase in ('saved','verified','refused','checking','last'):
        google.update(key_set=True,cx_set=True,state='saved')
    if phase in ('verified','last'):google.update(state='ready',verified=True,checked_at=int(time.time()))
    if phase=='refused':google.update(state='refused',problem='Google refused this connection. Check your existing API access, key and search engine ID.')
    if phase=='checking':google.update(state='checking',checking=True)
    if phase=='off':google=dict(OFF)
    if phase=='last':
        devices(wall,'artwork',host)
        google.update(pictures=12,last={'title':'Quiet water, late afternoon','source':'openverse','credit':'Authored QA artwork','art_url':'http://'+host+'/qa/art.png','at':int(time.time())-120,'frame':True})
        # Its own field, not wall.covers: nine mode composes every cover.
        wall.last_picture_png=last_picture_png()
    data['services']['google']=google
    wall.studies['/services']=data['services'];wall.studies['/display-session']={'active':False}
    return {'google':google}
