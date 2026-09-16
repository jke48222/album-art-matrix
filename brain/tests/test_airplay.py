"""Metadata framing, atomic names, artwork and RTP rollover, without AirPlay."""
import base64
import io
from types import SimpleNamespace
import numpy as np
from PIL import Image
from brain.features import Features
from brain.nowplaying.airplay import AirPlaySource, Metadata


def item(kind, code, payload=b''):
    return (f'<item><type>{kind.encode().hex()}</type><code>{code.encode().hex()}</code>'
            f'<length>{len(payload)}</length><data encoding="base64">\n'
            f'{base64.b64encode(payload).decode()}\n</data></item>\n').encode()


def source(tmp_path):
    now = [0.]
    ctrl = SimpleNamespace(features=Features({'features': {'airplay': True}}), nudge=lambda: None)
    source = AirPlaySource(ctrl, start=False, directory=tmp_path, clock=lambda: now[0])
    source.running = True
    return source, now


def test_fragmented_metadata_and_transaction(tmp_path):
    air, now = source(tmp_path)
    data = b''.join([item('ssnc','pbeg'), item('ssnc','snam',b'Fixture phone'),
        item('ssnc','mdst'), item('core','minm',b'Tower of Roses'),
        item('core','asar',b'MALI'), item('core','asal',b'Tower of Roses'), item('ssnc','mden'),
        item('ssnc','prgr',b'0/441000/8820000')])
    for offset in range(0,len(data),17): air.parser.feed(data[offset:offset+17])
    answer=air.get_current()
    assert (answer.title, answer.artist, answer.progress_ms, answer.duration_ms)==('Tower of Roses','MALI',10000,200000)
    now[0]=1.5
    assert air.get_current().progress_ms==11500
    air.consume('ssnc','paus',b'')
    now[0]=10
    assert air.get_current().progress_ms==11500 and not air.get_current().is_playing
    air.consume('ssnc','mdst',b'')
    air.consume('core','minm',b'A new song')
    assert air.get_current().title=='Tower of Roses'
    air.consume('ssnc','mden',b'')
    assert air.get_current().title=='A new song'


def test_artwork_rollover_and_disable(tmp_path):
    air, now=source(tmp_path)
    air.consume('core','minm',b'A song')
    frame=Image.fromarray(np.full((64,64,3), (180,80,40), dtype=np.uint8))
    buf=io.BytesIO(); frame.save(buf,format='PNG')
    air.consume('ssnc','PICT',buf.getvalue())
    assert air.art.startswith(b'\xff\xd8') and '/art/airplay.jpg?v=' in air.get_current().art_url
    air.consume('ssnc','prgr',f'{2**32-44100}/0/44100'.encode())
    assert air.get_current().progress_ms==1000 and air.get_current().duration_ms==2000
    air.ctrl.features=Features({})
    assert air.get_current() is None
    air.consume('core','minm',b'ignored')
    assert air.title=='A song'
    air._stop()
    assert not (air.directory/'cover.jpg').exists()


def test_malformed_then_good_item_recovers():
    received=[]
    parser=Metadata(lambda *args: received.append(args))
    parser.feed(b'<item><type>zz</type></item>'+item('core','minm',b'Good'))
    assert received==[('core','minm',b'Good')]


def test_missing_native_tools_is_clear(tmp_path,monkeypatch):
    from brain.nowplaying import airplay
    monkeypatch.setattr(airplay,'ROOT',tmp_path)
    air,_=source(tmp_path)
    import pytest
    with pytest.raises(FileNotFoundError,match='install-airplay'):
        air._start()
