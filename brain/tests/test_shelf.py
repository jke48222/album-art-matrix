"""Collection matching, durable page resumes and the physical ownership mark."""
import json
import threading
from pathlib import Path
from types import SimpleNamespace
import pytest
from PIL import Image
from brain.shelf import Shelf, match, normalize
from brain.art.pipeline import shelf_overlay
from brain.features import Features

FIXTURE=Path(__file__).parent/'fixtures/shelf.json'


def test_forty_tricky_releases():
    rows=json.loads(FIXTURE.read_text())
    assert len(rows)==40
    for row in rows:
        found=match(row['query_album'],row['query_artist'],rows)
        assert row['id'] in [r['id'] for r in found]
    assert not match('Unrelated album','Unrelated artist',rows)
    assert normalize('Beyoncé (2) feat. Jay-Z')=='beyonce'


def test_cd_is_not_owned_vinyl_and_mbid_fallback():
    vinyl={'id':1,'title':'Different spelling','artists':['A'],'formats':[{'name':'Vinyl'}],'release_group_mbid':'group'}
    cd={**vinyl,'id':2,'formats':[{'name':'CD'}]}
    assert match('Different spelling','A',[cd])==[]
    assert match('Other spelling','A',[vinyl,cd],'group')==[vinyl]


def test_resume_page_and_preserve_previous_collection(tmp_path):
    ctrl=SimpleNamespace(features=Features({'features':{'shelf':True}}))
    page=lambda ident,pages: {'pagination':{'pages':pages},'releases':[{'rating':4,'basic_information':{
        'id':ident,'title':'Record '+str(ident),'artists':[{'name':'Artist'}],'formats':[{'name':'Vinyl'}]}}]}
    first=Shelf(ctrl,path=tmp_path/'shelf.json',start=False)
    first._get=lambda *args: page(1,2)
    first.sync_page('owner','token')
    assert first.data['rows']==[] and first.data['sync']['page']==2
    resumed=Shelf(ctrl,path=tmp_path/'shelf.json',start=False)
    resumed._get=lambda *args: page(2,2)
    resumed.sync_page('owner','token')
    assert [r['id'] for r in resumed.data['rows']]==[1,2] and resumed.data['sync'] is None
    assert (tmp_path/'shelf.json').stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize('size,diameter,inset',[(64,5,2),(192,11,6)])
def test_marker_bounds_and_hole(size,diameter,inset):
    import numpy as np
    image=Image.new('RGB',(size,size))
    frame=np.asarray(shelf_overlay(image,'#dc7828'))
    y,x=np.where(frame.any(axis=2))
    assert (x.min(),x.max(),y.min(),y.max())==(size-inset-diameter,size-inset-1,size-inset-diameter,size-inset-1)
    middle=size-inset-diameter//2-1
    assert not frame[middle,middle].any()
    assert not np.asarray(image).any()
