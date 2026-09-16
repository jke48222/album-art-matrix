"""The actual native Olaf engine, with deterministic synthesized music."""
from dataclasses import asdict
import time
import numpy as np
import pytest

from brain.teach import Library, BIN, parse_matches, fingerprint_id, raw_float
from brain.nowplaying import NowPlaying


def sequence(seed, seconds=24):
    rng = np.random.default_rng(seed)
    t = np.arange(4000) / 16000
    chunks = []
    for _ in range(seconds * 4):
        freq = rng.choice(np.arange(220, 2600, 37), size=3, replace=False)
        sound = sum(np.sin(2 * np.pi * f * t) for f in freq) / 5
        envelope = np.minimum(t / .01, 1) * np.minimum((.25 - t) / .02, 1)
        chunks.append(sound * envelope + rng.normal(0, .03, len(t)))
    return (np.concatenate(chunks) * 32767).astype('<i2')


@pytest.fixture
def library(tmp_path):
    if not BIN.exists():
        pytest.skip('Run pi/install-olaf.sh to exercise the native engine')
    return Library(root=tmp_path)


def metadata():
    return asdict(NowPlaying('phone:fixture', 'Tone Sequence', 'Fixture Artist', 'Test Record',
                             'https://example.invalid/art.jpg', None, 24000, True, 'TEST123'))


def test_native_store_noisy_query_unrelated_forget(library):
    audio = sequence(71)
    track = metadata()
    ident = library.store(track, audio.tobytes(), 'room')
    noisy = audio[3*16000:12*16000].astype(np.float64)
    noisy += np.random.default_rng(89).normal(0, 400, len(noisy))
    before = time.monotonic()
    hit = library.query(np.clip(noisy, -32768, 32767).astype('<i2').tobytes(), minimum=12)
    elapsed = time.monotonic() - before
    assert hit is not None and hit[0].title == 'Tone Sequence'
    assert elapsed < 1
    assert library.query(sequence(983, 9).tobytes(), minimum=12) is None
    assert library.entries[ident]['times_matched'] == 1
    assert not any(p.suffix in {'.wav', '.raw', '.mp3'} for p in library.root.rglob('*'))
    loaded = Library(root=library.root)
    assert loaded.entries[ident]['times_matched'] == 1
    loaded.forget(ident)
    assert loaded.query(audio.tobytes()) is None
    assert not (library.root / (ident + '.csv')).exists()
    assert parse_matches(loaded._run(['query', '/dev/stdin', 'room'], raw_float(audio.tobytes()))) == []
    print(f'Olaf noisy-query latency: {elapsed:.3f}s')


def test_native_idempotent_store_and_clear(library):
    audio = sequence(4).tobytes()
    one = library.store(metadata(), audio, 'preview')
    two = library.store(metadata(), audio, 'room')
    assert one == two and len(library.entries) == 1
    library.clear()
    assert library.public()['songs'] == []
    assert not (library.root / 'db').exists()
    library.store(metadata(), audio, 'room')
    assert library.query(audio)


def test_parser_handles_commas_in_native_name():
    rows = 'matchCount, queryStart, queryStop, path, id, refStart, refStop\n21, 1.0, 4.0, Name, with comma, 123, 3.0, 6.0\n0,0,0,,0,0,0\n'
    assert parse_matches(rows) == [{'score': 21, 'id': '123', 'offset': 2.0}]


def test_library_identity_normalizes_titles():
    a = {'artist': 'An Artist', 'title': 'My Song (Single)'}
    b = {'artist': 'AN ARTIST', 'title': 'my song'}
    assert fingerprint_id(a) == fingerprint_id(b)


def test_room_capture_is_twenty_seconds_and_resets_on_silence(tmp_path):
    from types import SimpleNamespace
    from brain.features import Features
    from brain.teach import Teacher
    track = NowPlaying(**metadata())
    ctrl = SimpleNamespace(features=Features({'features': {'teach': True}}),
                           poller=SimpleNamespace(latest=track, asked_at=time.monotonic()))
    teacher = Teacher(ctrl, Library(root=tmp_path), start=False)
    settings = {'teach_by_ear': True}
    chunk = bytes(3200)
    for _ in range(100):
        teacher.feed(chunk, settings, True)
    teacher.feed(chunk, settings, False)
    for _ in range(199):
        teacher.feed(chunk, settings, True)
    assert teacher.jobs.empty()
    teacher.feed(chunk, settings, True)
    action, payload, generation = teacher.jobs.get_nowait()
    assert action == 'ear' and len(payload[1]) == 20 * 16000 * 2
    assert teacher._bytes == 0 and teacher._parts == []
    assert list(tmp_path.iterdir()) == []


def test_three_misses_and_switch_gate_preview_requests(tmp_path):
    from types import SimpleNamespace
    from brain.features import Features
    from brain.teach import Teacher
    ctrl = SimpleNamespace(features=Features({'features': {'teach': True}}),
                           poller=SimpleNamespace(latest=NowPlaying(**metadata()), asked_at=time.monotonic()))
    teacher = Teacher(ctrl, Library(root=tmp_path), start=False)
    teacher.miss(2)
    assert teacher.jobs.empty()
    teacher.miss(3)
    teacher.miss(4)
    assert teacher.jobs.qsize() == 1
    ctrl.features = Features()
    teacher.feed(bytes(3200), {'teach_by_ear': True}, True)
    assert teacher._parts == []
