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

# The three LED knobs the tuned About state moves. serve_setup.py's tuned
# phase moves the same three, so the About page counts 3 either way.
ABOUT_TUNED={'dither':0.3,'black_point':6,'gain_g':0.82}
ABOUT_STATES=('about','about-tuned','about-notuning','about-slow','about-badtuning')

def tuning_payload(changed=None):
    """GET /tuning as the brain answers it, with the brightness ceiling first.

    Built from brain/tuning.py's registry and control.py's ceiling alone. A
    Tuning is never constructed: that would rewrite the pipeline's constants
    and the renderer's launch-flag files. The wall has a microphone, so the
    listening knobs are live, and its renderer is running.
    """
    from types import SimpleNamespace
    from brain import tuning
    from brain.control import DEFAULTS,_with_ceiling
    shipped=tuning._shipped({})
    ear=SimpleNamespace(voice=object(),knocks=object(),library=object(),_library_kept=None)
    body=tuning.describe({**shipped,**(changed or {})},shipped,ears=ear,renderer={'state':'running','down_s':None})
    return _with_ceiling(body,DEFAULTS['panel_brightness'],DEFAULTS['panel_brightness'])

def configure_about(wall,phase,host=''):
    """The About page's wall: connected, with /tuning at defaults, tuned,
    missing (503), slow (6 s, held outside the fixture's lock) or empty."""
    devices(wall,'connected',host)
    if phase=='about-notuning':
        wall.statuses['/tuning']=(503,{'error':'tuning is not available on this wall'})
        return {'tuning':'unavailable'}
    if phase=='about-badtuning':
        wall.studies['/tuning']={}
        return {'tuning':'empty'}
    payload=tuning_payload(ABOUT_TUNED if phase=='about-tuned' else None)
    wall.studies['/tuning']=payload
    if phase=='about-slow':wall.delays['/tuning']=6.0
    changed=sorted(k for k,v in payload['values'].items() if v!=payload['defaults'][k])
    return {'tuning':{'changed':changed,'knobs':len(payload['knobs'])}}

def configure(wall,phase='ready',host=''):
    if phase in ABOUT_STATES:return configure_about(wall,phase,host)
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
