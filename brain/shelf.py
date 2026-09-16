"""The wall knows which records on your shelf match the music playing.

Connect Discogs once on the phone. The wall copies your collection and
refreshes it every six hours, keeping its last good copy when offline.
A tiny disc marks a streamed album you own on vinyl. The phone shows your
pressing's details and its marketplace price when available. Matching an
album cannot distinguish two pressings you own, so both remain visible.
"""
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import threading
import time
import unicodedata
from urllib.parse import quote

import requests

PATH = Path('~/.config/album-art-matrix/shelf.json').expanduser()
API = 'https://api.discogs.com'
INTERVAL = 6*3600
PACE = 1.1


def normalize(text):
    text = unicodedata.normalize('NFKD', str(text)).lower()
    text = re.sub(r'\([^)]*\)|\[[^]]*\]', ' ', text)
    text = re.split(r'\b(?:feat\.?|featuring|ft\.?)\s', text)[0]
    text = ''.join(c for c in text if not unicodedata.combining(c))
    return ' '.join(re.sub(r'[^\w]+', ' ', text).split())


def release(raw):
    basic = raw.get('basic_information', raw)
    artists = [a.get('name','') for a in basic.get('artists',[])]
    labels = [{'name': x.get('name',''), 'catno': x.get('catno','')} for x in basic.get('labels',[])]
    return {'id': int(basic['id']), 'title': basic.get('title',''), 'artists': artists,
        'year': basic.get('year'), 'labels': labels, 'formats': basic.get('formats',[]),
        'cover': basic.get('cover_image') or basic.get('thumb') or '',
        'rating': raw.get('rating',0), 'country': basic.get('country',''),
        'release_group_mbid': basic.get('release_group_mbid'),
        'url': f"https://www.discogs.com/release/{basic['id']}", 'played': 0}


def match(album, artist, rows, release_group_mbid=None):
    album, artist = normalize(album), normalize(artist)
    if not album or not artist:
        return []
    exact = [r for r in rows if normalize(r['title']) == album and
             any(normalize(a) == artist for a in [*r['artists'], ' '.join(r['artists'])]) and
             any(f.get('name','').lower() == 'vinyl' for f in r.get('formats',[]))]
    if exact:
        return sorted(exact, key=lambda r: (-r.get('rating',0),r['id']))
    if release_group_mbid:
        return [r for r in rows if r.get('release_group_mbid') == release_group_mbid and
                any(f.get('name','').lower() == 'vinyl' for f in r.get('formats',[]))]
    return []


class Shelf:
    def __init__(self, ctrl, path=PATH, session=None, start=True, clock=time.time):
        self.ctrl, self.path, self.clock = ctrl, Path(path), clock
        self.http = session or requests.Session()
        self.http.headers.update({'User-Agent': 'AlbumArtMatrix/1.0'})
        self.data = {'user':'', 'rows':[], 'synced':0, 'sync':None, 'prices':{}, 'details':{}}
        try:
            saved=json.loads(self.path.read_text())
            if isinstance(saved,dict) and isinstance(saved.get('rows'),list): self.data.update(saved)
        except (OSError, ValueError): pass
        self.problem=None
        self.busy=False
        self.current=[]
        self.counts={}
        self._journal_stamp=None
        self._source_key=None
        self.revision=0
        self._next_request=0.
        self._retry=0.
        self._credentials=None
        self._wake=threading.Event()
        if start:
            threading.Thread(target=self._work,name='shelf',daemon=True).start()

    def enabled(self):
        return self.ctrl.features.enabled('shelf')

    def changed(self):
        self._wake.set()

    def _save(self):
        self.path.parent.mkdir(parents=True,exist_ok=True)
        temp=self.path.with_suffix('.tmp')
        temp.write_text(json.dumps(self.data,ensure_ascii=False))
        os.chmod(temp,0o600)
        os.replace(temp,self.path)

    def _get(self,path,token):
        gap=self._next_request-time.monotonic()
        if gap>0:
            time.sleep(gap)
        if not self.enabled():
            raise ValueError('Shelf was switched off')
        result=self.http.get(API+path,headers={'Authorization': 'Discogs token='+token},timeout=8)
        self._next_request=time.monotonic()+PACE
        if result.status_code==429:
            try:
                wait=float(result.headers.get('Retry-After','60'))
            except ValueError:
                wait=60
            self._next_request=time.monotonic()+max(60,min(3600,wait))
        result.raise_for_status()
        if not self.enabled():
            raise ValueError('Shelf was switched off')
        return result.json()

    def sync_page(self,user,token):
        current=self.data['sync']
        if not current or current['user']!=user:
            current={'user':user,'page':1,'rows':[]}
            self.data['sync']=current
        page=self._get(f'/users/{quote(user,safe="")}/collection/folders/0/releases?per_page=100&page={current["page"]}',token)
        incoming=[release(row) for row in page.get('releases',[])]
        by_id={row['id']:row for row in current['rows']}
        for row in incoming:
            by_id[row['id']]=row
        current['rows']=list(by_id.values())
        pages=int(page.get('pagination',{}).get('pages',1))
        if current['page']>=pages:
            self.data.update(user=user,rows=current['rows'],sync=None,synced=self.clock())
            self.revision+=1
        else:
            current['page']+=1
        self._save()

    def rows(self):
        return [{**row, **self.data['details'].get(str(row['id']),{}),
                 'played':self.counts.get(str(row['id']),0),
                 'marketplace': self.data['prices'].get(str(row['id']),{}).get('value')}
                for row in self.data['rows']]

    def public(self):
        sync=self.data.get('sync')
        return {'enabled':self.enabled(), 'user':self.ctrl.services_store.get('discogs','user'),
            'token_set':bool(self.ctrl.services_store.get('discogs','token')), 'busy':self.busy,
            'synced':self.data['synced'] or None,'page':sync['page'] if sync else None,
            'count':len(self.data['rows']), 'problem':self.problem, 'rows':self.rows(),
            'current':self.current, 'revision':self.revision}

    def update_current(self):
        poller=getattr(self.ctrl,'poller',None)
        now=poller.latest if poller else None
        rows=self.rows()
        current=match(now.album,now.artist,rows,getattr(now,'release_group_mbid',None)) if now else []
        source_key=now.track_id if now else None
        if current!=self.current or source_key!=self._source_key:
            self._source_key=source_key
            self.current=current
            self.revision+=1
            self.ctrl.dirty.set()
        journal=self.ctrl.journal_read(10000)
        stamp=(len(journal), journal[0].get('ts') if journal else None,
               self.data['synced'], len(rows))
        if stamp != self._journal_stamp:
            index={}
            for row in rows:
                if not any(f.get('name','').lower()=='vinyl' for f in row['formats']):
                    continue
                for artist in row['artists']:
                    index.setdefault((normalize(row['title']),normalize(artist)),[]).append(str(row['id']))
            counts=Counter()
            for entry in journal:
                for ident in index.get((normalize(entry.get('album','')),normalize(entry.get('artist',''))),[]):
                    counts[ident]+=1
            self.counts=dict(counts)
            self._journal_stamp=stamp

    def streamed_mark(self):
        if not self.enabled() or not self.ctrl.tuning or not self.ctrl.tuning.get('shelf_mark') or not self.current:
            return False
        poller=getattr(self.ctrl,'poller',None)
        now=poller.latest if poller else None
        return bool(now and now.is_playing and not now.track_id.startswith(('ears:','airplay:')))

    def enrich(self,token):
        # Country is omitted by some collection responses. Fetch details
        # and prices for the record in use instead of hammering every release.
        for row in self.current:
            ident=str(row['id'])
            if ident not in self.data['details']:
                detail=self._get('/releases/'+ident,token)
                self.data['details'][ident]={'country':detail.get('country',''),
                    'labels':detail.get('labels',row['labels']), 'year':detail.get('year',row['year'])}
                self._save()
            price=self.data['prices'].get(ident,{})
            if self.clock()-price.get('at',0)>3600:
                stats=self._get('/marketplace/stats/'+ident,token)
                self.data['prices'][ident]={'at':self.clock(),'value':stats}
                self._save()

    def _work(self):
        while True:
            self._wake.wait(2)
            self._wake.clear()
            if not self.enabled():
                if self.current:
                    self.current=[]
                    self.revision+=1
                    self.ctrl.dirty.set()
                continue
            user=self.ctrl.services_store.get('discogs','user')
            token=self.ctrl.services_store.get('discogs','token')
            credentials=(user,hashlib.sha256(token.encode()).hexdigest())
            if credentials!=self._credentials:
                self._credentials=credentials
                self._retry=0
                if user!=self.data['user']:
                    self.data.update(user=user,rows=[],sync=None,synced=0,prices={},details={})
                    self._save()
                elif token:
                    self.data['synced']=0
            self.update_current()
            if not user or not token:
                self.problem='Add a Discogs username and personal token in Services.'
                continue
            if self.clock()<self._retry:
                continue
            try:
                self.busy=True
                if self.data['sync'] or self.clock()-self.data['synced']>=INTERVAL:
                    self.sync_page(user,token)
                self.enrich(token)
                self.update_current()
                self.problem=None
            except (requests.RequestException, ValueError, KeyError, OSError) as exc:
                self.problem=f'Shelf update paused: {type(exc).__name__}. Keeping the last collection.'
                self._retry=self.clock()+60
                print('[shelf] '+self.problem,flush=True)
            finally:
                self.busy=False
