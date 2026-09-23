"""Ticker composition, multilingual inks and the real runtime lifecycle."""
import threading
import time

import numpy as np
import pytest
from brain.art.pixelfont import cell, draw_text, normalize, text_width
from brain.art.text_modes import Crawl, Ticker, wrap_text


@pytest.mark.parametrize("source,expected", [
    ("I <3 YOU", "I ♥ YOU"),
    ("❤️A", "♥A"),
    ("♥︎A", "♥A"),
    ("Cafe\u0301", "Café"),
    ("A\r\nB\rC\tD\u00a0E", "A\nB\nC D E"),
    ("A\u200b\u200c\u200d\ufeffB\U000e0100", "AB"),
    ("A\x00B", "AB"),
])
def test_visible_normalization_is_stable(source, expected):
    assert normalize(source) == expected
    assert normalize(expected) == expected


@pytest.mark.parametrize("side", [64, 192])
@pytest.mark.parametrize("text", ["AB CD", "가나다", "Wé♥", "I ❤️ YOU"])
def test_individual_inks_preserve_the_original_glyph_layout(side, text):
    plain = Ticker(side, text, color="#ffffff")
    inked = Ticker(side, text, color="#ffffff", colors=["#ffffff"] * 30)
    stamp = side / plain.px_per_s
    assert np.array_equal(plain.frame_at(stamp), inked.frame_at(stamp))


@pytest.mark.parametrize("side", [64, 192])
def test_heart_is_one_colored_cell_and_next_letter_keeps_its_ink(side):
    ticker = Ticker(side, "❤️A", color="#ffffff", colors=["#ff0000", "#00ff00"])
    actual = np.asarray(ticker.frame_at(side / ticker.px_per_s))
    expected = np.zeros_like(actual)
    y = (side - 7 * ticker.SCALE) // 2
    draw_text(expected, "♥", 0, y, (255, 0, 0), ticker.SCALE)
    draw_text(expected, "A", 6 * ticker.SCALE, y, (0, 255, 0), ticker.SCALE)
    assert np.array_equal(actual, expected)


def test_across_has_identical_size_relative_motion_and_loop_gap():
    small = Ticker(64, "MEET AT SIX", colors=["#ce653c", "#a2e0cd"])
    large = Ticker(192, "MEET AT SIX", colors=["#ce653c", "#a2e0cd"])
    assert large.px_per_s == small.px_per_s * 3
    assert large.travel == small.travel * 3
    assert large.travel / large.px_per_s == small.travel / small.px_per_s
    for stamp in [0, 1, 2, 4, 7, 9]:
        expected = np.repeat(np.repeat(np.asarray(small.frame_at(stamp)), 3, axis=0), 3, axis=1)
        assert np.array_equal(large.frame_at(stamp), expected)


@pytest.mark.parametrize("tilt", [False, True])
def test_rising_composition_scales_without_rewrapping_or_changing_inks(tilt):
    text = "MEET AT SIX\n\n가나다 Wé♥"
    colors = ["#ff3300", "#88ff00", "#0044ff"] * 20
    small, large = [Crawl(side, text, colors=colors, tilt=tilt) for side in [64, 192]]
    assert large.mask.shape == (small.mask.shape[0] * 3, 192, 3)
    # An odd-width line centres one pixel more precisely on the larger panel;
    # compare the ink itself while checking the centre stays in the same cell.
    for top in range(0, small.h - 1, 9):
        a, b = small.mask[top:top + 9], large.mask[top * 3:(top + 9) * 3]
        ax, bx = np.where(a.any(axis=(0, 2)))[0], np.where(b.any(axis=(0, 2)))[0]
        if not ax.size:
            assert not bx.size
            continue
        assert abs(bx[0] - ax[0] * 3) < 3
        expected = np.repeat(np.repeat(a[:, ax[0]:ax[-1] + 1], 3, axis=0), 3, axis=1)
        assert np.array_equal(b[:, bx[0]:bx[-1] + 1], expected)
    assert large.px_per_s == small.px_per_s * 3
    # Perspective sampling differs by at most one logical source row between
    # panels; the blank interval and reading pace remain size-relative.
    assert abs(large.travel / large.px_per_s - small.travel / small.px_per_s) < 0.6


@pytest.mark.parametrize("side", [64, 192])
def test_rising_world_glyphs_use_their_real_advance(side):
    scale = side // 64
    text = "가나다 Wé♥"
    crawl = Crawl(side, text, color="#ffffff")
    expected = np.zeros((crawl.h, side, 3), dtype=np.uint8)
    lines = wrap_text(normalize(text), side - 4 * scale, scale)
    for index, line in enumerate(lines):
        draw_text(expected, line, (side - text_width(line, scale)) // 2,
                  index * 9 * scale, (255, 255, 255), scale)
    assert np.array_equal(crawl.mask, expected.astype(np.float32) / 255)


@pytest.mark.parametrize("side", [64, 192])
@pytest.mark.parametrize("glyph", ["É", "Ç", "Ģ", "À"])
def test_accents_and_descenders_keep_every_ink_pixel_in_all_ticker_styles(side, glyph):
    rows, _, _, dy = cell(glyph)
    assert dy < 0 or dy + len(rows) > 7  # Exercise actual extended World7 cells.
    lit_cells = sum(int(row).bit_count() for row in rows)
    across = Ticker(side, glyph, color="#ffffff")
    frame = np.asarray(across.frame_at(side / across.px_per_s))
    assert np.count_nonzero(frame.max(axis=2)) == lit_cells * across.SCALE ** 2
    ys = np.where(frame.max(axis=2))[0]
    assert ys.min() > 0 and ys.max() < side - 1
    for tilt in [False, True]:
        crawl = Crawl(side, glyph, color="#ffffff", tilt=tilt)
        assert np.count_nonzero(crawl.mask.max(axis=2)) == lit_cells * (side // 64) ** 2


@pytest.mark.parametrize("side", [64, 192])
def test_extended_lines_preserve_authored_blank_line_spacing_and_inks(side):
    scale = side // 64
    crawl = Crawl(side, "É\n\nÇ\nĢ", colors=["#ff0000", "#00ff00", "#0000ff"])
    bounds = []
    for channel, glyph in enumerate("ÉÇĢ"):
        plane = crawl.mask[:, :, channel]
        rows = cell(glyph)[0]
        assert np.count_nonzero(plane) == sum(int(row).bit_count() for row in rows) * scale ** 2
        y = np.where(plane)[0]
        bounds.append((y.min(), y.max()))
    # Two rows of normal leading plus the nine-row authored blank paragraph.
    assert bounds[1][0] - bounds[0][1] - 1 >= 11 * scale
    assert bounds[2][0] - bounds[1][1] - 1 >= 2 * scale


def test_paragraphs_and_long_words_keep_their_words_and_blank_lines():
    lines = wrap_text("ONE\n\nTWO SUPERLONGWORD", 23, 1)
    assert lines[:3] == ["ONE", "", "TWO"]
    assert "".join(lines) == "ONETWOSUPERLONGWORD"
    assert all(text_width(line, 1) <= 23 for line in lines)
    assert Ticker(64, "ONE\nTWO").text == "ONE TWO"


@pytest.mark.parametrize("factory", [Ticker, Crawl, lambda *args, **kwargs: Crawl(*args, **kwargs, tilt=True)])
@pytest.mark.parametrize("side", [64, 192])
def test_once_finishes_at_blank_frame_and_loop_starts_over(factory, side):
    once = factory(side, "HELLO", loop=False)
    end = once.travel / once.px_per_s
    assert not once.done(end - .001)
    assert once.done(end + .001)
    assert not np.asarray(once.frame_at(end + .001)).any()
    loop = factory(side, "HELLO", loop=True)
    assert not loop.done(end * 3)
    assert np.array_equal(loop.frame_at(0), loop.frame_at(end))


def test_runtime_restarts_a_completed_message_and_an_identical_resend(monkeypatch):
    """Exercise main's real branch, replacing only sources, IO and clock pace."""
    from brain import main as runtime
    from brain.features import KNOWN

    stop = threading.Event()
    controls, instances, errors = [], [], []

    class EndLoop(BaseException):
        pass

    class Sink:
        def show(self, *args, **kwargs):
            if stop.is_set():
                raise EndLoop()

    class FastTicker(Ticker):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.px_per_s *= 20
            instances.append(self)

    class SilentSource:
        name = "fixture"

        def get_current(self):
            return None

    def sources(config, control):
        controls.append(control)
        return [SilentSource()]

    config = {
        "panel": {"width": 64, "height": 64},
        "sink": {"type": "preview"},
        "nowplaying": {"poll_seconds": .02},
        "features": {name: False for name, _ in KNOWN},
    }
    monkeypatch.setattr(runtime, "load_config", lambda path: config)
    monkeypatch.setattr(runtime, "build_sources", sources)
    monkeypatch.setattr(runtime, "make_sink", lambda *args: Sink())
    monkeypatch.setattr(runtime, "serve_control", lambda *args: None)
    monkeypatch.setattr(runtime, "Ticker", FastTicker)
    monkeypatch.setattr("sys.argv", ["brain", "--config", "fixture"])

    def run():
        try:
            runtime.main()
        except EndLoop:
            pass
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    def wait(predicate):
        deadline = time.monotonic() + 4
        while not predicate() and not errors and time.monotonic() < deadline:
            time.sleep(.01)
        assert not errors, errors
        assert predicate()

    try:
        wait(lambda: bool(controls))
        ctrl = controls[0]
        ctrl.apply({"mode": "ticker", "ticker_text": "A", "ticker_loop": False,
                    "ticker_style": "across"})
        wait(lambda: len(instances) == 1)
        wait(lambda: ctrl.get()["mode"] == "art")
        ctrl.apply({"mode": "ticker"})
        wait(lambda: len(instances) == 2)
        wait(lambda: ctrl.get()["mode"] == "art")
        ctrl.apply({"mode": "ticker", "ticker_loop": True})
        wait(lambda: len(instances) == 3)
        revision = ctrl.ticker_revision
        ctrl.apply({"ticker_text": "A"})
        assert ctrl.ticker_revision > revision
        wait(lambda: len(instances) == 4)
        assert instances[2].text == instances[3].text
        assert ctrl.get()["mode"] == "ticker"
    finally:
        stop.set()
        if controls:
            controls[0].apply({"mode": "clock"})
            controls[0].dirty.set()
            controls[0].news.set()
        thread.join(5)
        assert not thread.is_alive()
