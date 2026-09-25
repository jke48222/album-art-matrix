"""Deterministic, isolated API fixtures for native discovery capture; no inference."""
from io import BytesIO
import time
import base64
from pathlib import Path
from PIL import Image


def configure(wall, host, phase, pixels, feature=""):
    wall.capture_frame = None
    from brain import tuning
    png=BytesIO(); Image.frombytes('RGB',(64,64),pixels).resize((512,512),Image.Resampling.NEAREST).save(png,'PNG')
    wall.covers['/qa-discovery.png']=png.getvalue()
    wall.covers['/imagine/qa-art.png']=png.getvalue()
    art=f'http://{host}/qa-discovery.png'
    missing=phase=='missing-key'
    wall.studies['/show']={'last':None,'busy':False,'problem':None}
    wall.studies['/earworm']={'last':None,'ready':not missing,'pending':False}
    wall.studies['/imagine']={'ready':not missing,'provider':'openai','model':'gpt-image-1.5','quality':'medium','busy':False,'cooldown_s':0,'images':[], 'live':{'stage':'idle'}}
    if phase in {'result','ready','listening'}:
        wall.studies['/imagine']['images']=[{'id':'qa-art','prompt':'An amber sun over a quiet sea, paper-cut layers','provider':'openai','ts':int(time.time())-3600}]
    if phase=='thinking':
        wall.studies['/imagine'].update({'busy':True,'job_id':'qa-job','live':{'stage':'waiting','prompt':'An amber sun over a quiet sea','elapsed':24,'partials':0,'of':3}})
        wall.studies['/show'].update({'pending':True,'query':'The coast at golden hour'})
        wall.studies['/earworm'].update({'pending':True})
    if phase=='failed':
        wall.studies['/imagine']['problem']='The image service could not finish this picture. Your words are kept below.'
        wall.studies['/imagine']['live']={'stage':'failed','prompt':'An amber sun over a quiet sea','problem':'The image provider did not finish. Try again when it is available.'}
    if phase=='result':
        small=BytesIO();Image.frombytes('RGB',(64,64),pixels).save(small,'PNG')
        preview=base64.b64encode(small.getvalue()).decode()
        result={'id':'qa-discovery','what':'show','kind':'picture','title':'Amber light over the sea','source':'Authored QA fixture','art_url':art,'preview_png':preview,'preview_size':64,'shown':True,'active':True,'seconds_left':540}
        wall.studies['/show']['last']=result
        wall.studies['/earworm']['last']={**result,'id':'qa-song','what':'earworm','title':'Into the Quiet','artist':'The Tessera Sessions','words':'A little colour in the quiet','confidence':.88,'alternatives':[{'title':'Amber Hours','artist':'Mira Vale'}]}
        wall.studies['/imagine'].update({'on_wall':True,'showing_id':'qa-art','live':{'stage':'done','prompt':'An amber sun over a quiet sea','partials':3,'of':3}})
    level=-36.0
    hearing={'on':True,'tools':True,'mic':'USB Audio Device','listening':True,'state':'heard','level_db':level,'floor_db':-67.0,'gate_db':-52.0,'gate_open':True,'loud_s':18,'window_s':6,'attempts':12,'matches':9,'heard_s':3,'match_source':'local','heard':{'title':'Into the Quiet','artist':'The Tessera Sessions','album':'After the Rain','at_s':93,'length_s':245},'recent':[{'title':'Amber Hours','artist':'Mira Vale','album':'Amber Hours','ago_s':240,'times':1}],'knock':{'knock':True,'whistle':True,'knocks':{'candidates':4,'doubles':2},'whistles':{'count':1}}}
    if phase=='quiet': hearing.update(state='quiet',level_db=-65,gate_open=False,heard=None)
    if phase=='faint': hearing.update(state='faint',heard=None,pending={'title':'A distant melody','artist':'Unknown recording','album':'','heard_s':4})
    if phase=='failed': hearing.update(state='no_mic',listening=False,mic=None,heard=None,level_db=None,problem='No microphone found. Check the wall’s USB connection.')
    wall.studies['/services']={'hearing':hearing,'ears':True,'claude':{'ready':not missing},'images':{'ready':not missing,'provider':'openai'}}
    wall.studies['/teach']={'enabled':True,'landmarks':1239,'songs':[]}
    specs=getattr(tuning,'KNOBS',getattr(tuning,'SPECS',[]))
    keys=['name','group','kind','min','max','step','restart','note']
    knobs=[dict(zip(keys,k)) for k in specs if k[1] in ('Hearing','Voice')]
    vals={k['name']:(True if k['kind']=='bool' else (k['min']+k['max'])/2) for k in knobs}
    vals.update({'room_gate':-52,'mic_gain':65,'knock_sensitivity':20,'wake_threshold':.5})
    wall.studies['/tuning']={'knobs':knobs,'values':vals,'defaults':vals}
    voice={'on':True,'state':'listening' if phase=='listening' else 'thinking' if phase=='thinking' else 'idle','wakes':12,'last_text':'Show the clock','last_command':'Clock','wake':{'model':'hey_jarvis','label':'Hey Jarvis','loaded':True,'kind':'built-in','threshold':.5,'default_threshold':.5,'fires':12},'wake_choices':[{'name':'hey_jarvis','label':'Hey Jarvis','kind':'built-in'},{'name':'alexa','label':'Alexa','kind':'built-in'}],'speech':{'model':'base.en','loaded':True,'last_s':1.8},'mic':{'level_db':-36,'floor_db':-67,'fresh':True},'mic_available':True,'history':[{'id':'qa-command','text':'Show the clock','command':'clock','at':int(time.time())-32}]}
    wall.studies['/voice']=voice
    wall.studies['/voice/meter']={'level_db':-36,'floor_db':-67,'level_over':31,'score':.22,'threshold':.5,'state':voice['state'],'wake':.22,'peak':.63,'fresh':True,'mic_available':True,'last_audio_ago':.1}

    case = ("earworm-result" if feature == "earworm" and phase == "result" else
            "imagine-done" if feature == "imagine" and phase == "result" else
            "imagine-waiting" if feature == "imagine" and phase == "thinking" else
            "voice-" + phase if feature == "voice" and phase in ("listening", "thinking") else None)
    if case:
        path=Path(__file__).resolve().parents[2]/'qa/batch-08/wall/after'/f'{case}-64.png'
        frame=Image.open(path).convert('RGB')
        wall.capture_frame=frame.tobytes()
        if feature=='earworm':
            native=BytesIO();frame.save(native,'PNG')
            wall.studies['/earworm']['last']['preview_png']=base64.b64encode(native.getvalue()).decode()
        if feature=='imagine':wall.studies['/imagine']['on_wall']=True
