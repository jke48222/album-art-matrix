"""Synthetic service statuses for local native captures; no credentials or external writes."""
def configure(wall, phase):
    payload={
      'spotify':{'client_id':'1234567890abcdef1234567890abcdef','linked':phase in ('connected','expired','refused','unavailable'),'state':'idle' if phase=='connected' else phase if phase in ('expired','refused','unavailable') else 'unlinked','problem':'Spotify access expired. Sign in again.' if phase=='expired' else 'Spotify is temporarily unavailable.' if phase=='unavailable' else None,'can_retry':phase=='unavailable'},
      'lastfm':{'user':'','key_set':False},'listenbrainz':{'user':'','token_set':False},
      'ears':False,'hearing':{'on':False,'tools':False,'listening':False,'state':'off','gate_open':False},
      'airplay':{'running':False,'state':'off'},'mac':{'endpoint':'','answering':False},
      'source_order':['phone','airplay','applemusic','spotify','lastfm','listenbrainz','ears']}
    wall.studies['/services']=payload
    return payload
