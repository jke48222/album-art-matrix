"""Album-Art Matrix brain: poll now-playing, run the art pipeline on track
change, push the frame to the sink — under live control of the phone app.

Mac (dev):  .venv/bin/python -m brain.main --config config.toml   (sink=preview)
Pi (live):  same, with [sink] type = "pi", pi/run_renderer.sh running, and
            [applemusic] endpoint pointed at the Mac's reporter.

The control API (brain/control.py, port 8788) decides what the wall shows:
  art     static album sleeve          cd    spinning-disc render
  ambient light effects, no music      off   dark (brain keeps running)
Brightness scales the white-balance gains in linear light, so dimming
doesn't shift color. A control change wakes the loop instantly (dirty event).
"""
import argparse
import sys
import time

if sys.version_info < (3, 11):
    sys.exit("python >= 3.11 required (tomllib) — found "
             + ".".join(map(str, sys.version_info[:3])))
import tomllib

from PIL import Image

from .art.disc import DiscAnimator
from .art.effects import Ambient
from .art.fetch import fetch_art
from .art.lyrics import LyricBook, LyricCanvas
from .art.nine import NineBuilder
from .art.pipeline import apply_finish, dominant_colors, prepare, white_balance
from .art.text_modes import Clock, Countdown, Crawl, Ticker
from .control import ControlState, serve as serve_control
from .nowplaying import SourceChain
from .sun import sun_factor
from .nowplaying.acoustid import AcoustidSource
from .nowplaying.applemusic import AppleMusicSource
from .nowplaying.applemusic_account import AppleMusicAccountSource, configured as account_configured
from .nowplaying.lastfm import LastfmSource
from .nowplaying.listenbrainz import ListenBrainzSource
from .nowplaying.macmedia import MacMediaSource
from .nowplaying.pushed import PushedSource
from .nowplaying.spotify import SpotifySource
from .services import Services
from .sinks.mac_preview import MacPreviewSink
from .sinks.pi_renderer import PiRendererSink


def load_config(path: str) -> dict:
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def make_sink(cfg: dict, override: str | None = None):
    kind = override or cfg["sink"]["type"]
    if kind == "pi":
        return PiRendererSink(cfg["sink"].get("fifo", "/tmp/album-frame.fifo"))
    if kind == "preview":
        return MacPreviewSink(cfg["sink"].get("preview_dir", "preview_out"))
    raise ValueError(f"unknown sink type: {kind}")


DEFAULT_ORDER = ["phone", "applemusic", "spotify", "lastfm", "listenbrainz", "acoustid"]


def build_sources(cfg: dict, ctrl):
    """The chain, first answer wins:
      phone        what the app posts to /push (no Mac needed)
      applemusic   on a Mac: Music.app, then anything else the Mac plays
                   (media-control), then the account view via the helper;
                   on the Pi: the account view straight from MusicKit
      spotify      the API, for any device; tokens arrive from the phone
      lastfm       Spotify, Tidal and Deezer reporting through one account
      listenbrainz the open ledger; reading it needs no key at all
      acoustid     the wall's own microphone, for anything out loud
    Every adapter is built whether or not it has its details yet: the phone
    hands them over later (POST /services) and the adapter starts answering
    with no restart. config.toml's list is the order of preference; anything
    it leaves out still comes after, so a service connected from the phone
    always has somewhere to be."""
    store = Services(cfg)
    ctrl.services_store = store
    order = [str(n) for n in cfg.get("nowplaying", {}).get("adapters", DEFAULT_ORDER)]
    order += [n for n in DEFAULT_ORDER if n not in order]
    sources = []
    for name in order:
        if name == "phone":
            ctrl.pushed = PushedSource()
            sources.append(ctrl.pushed)
        elif name == "applemusic":
            endpoint = cfg.get("applemusic", {}).get("endpoint", "")
            if endpoint:
                ctrl.apple = AppleMusicSource(endpoint)
                sources.append(ctrl.apple)
            elif sys.platform == "darwin":
                mac = None
                if MacMediaSource.available():
                    mac = MacMediaSource()
                    print("[main] mac: anything this Mac plays is read too "
                          "(media-control)")
                else:
                    print("[main] mac: only Music.app is read on this Mac; "
                          "`brew install media-control` adds every other app")
                ctrl.apple = AppleMusicSource("", mac=mac)
                sources.append(ctrl.apple)
            elif account_configured():
                sources.append(AppleMusicAccountSource())
            else:
                print("[main] applemusic: no MusicKit credentials on this machine "
                      "(deploy.sh copies them) — skipping")
        elif name == "spotify":
            sp = SpotifySource(store.get("spotify", "client_id"),
                               int(cfg.get("spotify", {}).get("redirect_port", 8888)))
            ctrl.spotify = sp
            sources.append(sp)
            print("[main] spotify: " + ("signed in" if sp.linked else
                                        "app id set, not signed in yet" if sp.client_id
                                        else "no app id yet; set one from the phone"))
        elif name == "lastfm":
            lf = LastfmSource(store.get("lastfm", "api_key"), store.get("lastfm", "user"))
            ctrl.lastfm = lf
            sources.append(lf)
            print(f"[main] lastfm: {'following ' + lf.user if lf.configured else 'not set up'}")
        elif name == "listenbrainz":
            lb = ListenBrainzSource(store.get("listenbrainz", "user"))
            ctrl.listenbrainz = lb
            sources.append(lb)
            print(f"[main] listenbrainz: {'following ' + lb.user if lb.configured else 'not set up'}")
        elif name == "acoustid":
            ac = AcoustidSource(store.get("acoustid", "api_key"),
                                store.get("acoustid", "device") or "auto")
            ctrl.acoustid = ac
            sources.append(ac)
            print(f"[main] acoustid: {'listening' if ac.status()['listening'] else 'key set, waiting for a microphone' if ac.configured else 'no key yet'}")
        else:
            print(f"[main] adapter {name!r} unknown — skipping")
    if not sources:
        sys.exit("[main] no now-playing sources configured")
    return sources


class _FrameTee:
    """Wraps the sink so the control API always has the current frame
    (pre-white-balance when available — that's what the phone previews)."""

    def __init__(self, sink, ctrl, size):
        self._sink, self._ctrl, self._size = sink, ctrl, size

    def show(self, rgb888: bytes, pre_wb_img=None):
        self._ctrl.last_frame = (pre_wb_img.tobytes()
                                 if pre_wb_img is not None else rgb888)
        self._sink.show(rgb888, pre_wb_img=pre_wb_img)


def main():
    ap = argparse.ArgumentParser(description="Album-Art Matrix brain")
    ap.add_argument("--config", default="config.toml")
    ap.add_argument("--sink", choices=["preview", "pi"],
                    help="override [sink] type from the config")
    ap.add_argument("--once", action="store_true",
                    help="poll once, render once, exit (for testing)")
    args = ap.parse_args()

    cfg = load_config(args.config)
    size = int(cfg["panel"]["width"])
    wb = cfg["whitebalance"]
    gains = (float(wb["r"]), float(wb["g"]), float(wb["b"]))
    pipe = cfg.get("pipeline", {})
    poll_s = float(cfg.get("nowplaying", {}).get("poll_seconds", 5.0))

    anim = cfg.get("animation", {})
    anim_fps = float(anim.get("fps", 120))
    # The achieved rate is a measurement, not the target: if the Pi cannot hold
    # anim_fps this is where you find out, instead of guessing from a video.
    fps_count, fps_since, fps_last = 0, time.monotonic(), 0.0
    fps_lastc = time.monotonic()     # when the meter last counted a frame
    # Absolute deadline, not "now + budget". Event.wait() overshoots by around
    # a millisecond, and adding that to a fresh `now` every pass compounds it:
    # at a 120 fps target that alone cost ~15% of the frames.
    deadline = time.monotonic()
    ctrl = ControlState(seed={
        "mode": "cd" if anim.get("mode") == "cd" else "art",
        "rpm": float(anim.get("rpm", 7.5)),
    }, frame_len=size * size * 3)
    source = SourceChain(build_sources(cfg, ctrl))
    ctrl.source = source
    serve_control(ctrl, int(cfg.get("control", {}).get("port", 8788)))
    sink = _FrameTee(make_sink(cfg, args.sink), ctrl, size)

    print(f"[main] adapters: {[s.name for s in source.sources]}, "
          f"panel {size}x{size}, poll {poll_s:.0f}s, "
          f"gains R{gains[0]:.2f}/G{gains[1]:.2f}/B{gains[2]:.2f}")

    last_track, last_pre = None, None
    animator, t0 = None, time.monotonic()
    ambient, amb_key, amb_t0 = None, None, time.monotonic()
    blacked, need_show = False, False
    fin_key, fin_img, frame_shown = None, None, None
    hold_until = 0.0                 # replays pin the wall for a while
    quiet_since = None               # when the music stopped, for idle
    # Where the song is, and when we last heard that. The record turns from
    # this rather than from the wall clock, so a seek seeks the record.
    prog = None                      # (seconds_in, monotonic_at, playing, total)
    ticker, ticker_key, ticker_t0 = None, None, 0.0
    countdown, countdown_key = None, None
    nine = NineBuilder(size)
    nine_shown = None
    lyric_book = LyricBook()
    lyric_canvas, lyric_key = None, None
    woke_on = None                   # date the wake fade last fired
    sun_f, sun_at = 1.0, 0.0         # evening factor, refreshed each poll
    away_forced = None               # mode we left when the wall went away
    clock, clock_key = None, None
    clip_i, clip_next = 0, 0.0
    black = bytes(size * size * 3)
    idle_prev = None                 # which idle override is currently applied

    def show_sleeve(art_url):
        """The one path that puts a sleeve on the wall: fetch, prepare, arm
        the disc animator, extract colours. Callers add their bookkeeping."""
        nonlocal last_pre, animator, t0, need_show
        pre = prepare(
            fetch_art(art_url), size,
            unsharp_radius=float(pipe.get("unsharp_radius", 1.0)),
            unsharp_percent=int(pipe.get("unsharp_percent", 60)),
        )
        last_pre = pre
        animator = DiscAnimator(pre, size, rpm=ctrl.get()["rpm"])
        t0 = time.monotonic()
        need_show = True
        ctrl.art_colors = dominant_colors(pre)

    def pace(tick):
        """Frame pacing + fps meter shared by the animated modes. The absolute
        deadline carries the Event.wait overshoot fix; the meter restarts its
        window after any stint in a non-animated mode, so the first report
        after one is a measurement, not an average over the idle gap."""
        nonlocal deadline, fps_count, fps_since, fps_last, fps_lastc
        if tick - fps_lastc > 1.0:
            fps_count, fps_since = 0, tick
        fps_lastc = tick
        fps_count += 1
        if tick - fps_since >= 5.0:
            fps_last = fps_count / (tick - fps_since)
            ctrl.fps_last = fps_last
            print(f"[main] {fps_last:.0f} fps sustained "
                  f"(target {anim_fps:.0f})")
            fps_count, fps_since = 0, tick
        deadline = max(deadline + 1.0 / anim_fps, tick)
        gap = deadline - time.monotonic()
        if gap > 0 and ctrl.dirty.wait(gap):
            ctrl.dirty.clear()

    while True:
        # ---- phone asked to re-show something from the journal ----------
        if ctrl.replay is not None:
            entry, ctrl.replay = ctrl.replay, None
            try:
                show_sleeve(entry["art_url"])
                ctrl.now_showing = {"title": entry.get("title", "?"),
                                    "artist": entry.get("artist", "?"),
                                    "album": entry.get("album", "")}
                ctrl.shown_seq += 1
                hold_until = time.monotonic() + 600   # current track waits
                print(f"[main] replay: {entry.get('artist')} — "
                      f"{entry.get('title')}")
            except Exception as exc:
                print(f"[main] replay failed: {exc}")

        # ---- poll now-playing; rebuild art state on track change --------
        now = source.get_current()

        # Silence is a state worth having an opinion about. A wall left on a
        # frozen sleeve all night is a different object from one that quietly
        # goes dark, so this is the owner's call, not ours.
        if now is not None and now.is_playing:
            quiet_since = None
        elif quiet_since is None:
            quiet_since = time.monotonic()

        # ---- nobody home ------------------------------------------------
        # Presence is the phone talking to the reporter, or the app talking
        # to us. Both quiet for 15 minutes with nothing playing reads as an
        # empty house, and a lamp burning for an empty house is the owner's
        # choice to make, not a default.
        if ctrl.get().get("away") == "off":
            ages = []
            phone_age = next((sc.phone_age for sc in source.sources
                              if getattr(sc, "phone_age", None) is not None), None)
            if phone_age is not None:
                ages.append(phone_age)
            if ctrl.last_client is not None:
                ages.append(time.monotonic() - ctrl.last_client)
            present_age = min(ages) if ages else None
            mode_now = ctrl.get()["mode"]
            if away_forced and mode_now != "off":
                away_forced = None           # someone chose something; defer
            if present_age is not None:
                playing = bool(now and now.is_playing)
                if present_age > 900 and not playing and mode_now != "off":
                    away_forced = mode_now
                    ctrl.apply({"mode": "off"})
                    print("[main] nobody around for a while; wall off")
                elif away_forced and present_age < 60 and mode_now == "off":
                    print("[main] someone is back; wall on")
                    ctrl.apply({"mode": away_forced})
                    away_forced = None
        else:
            away_forced = None

        # ---- evenings ---------------------------------------------------
        # Recomputed once a minute at most: the sun does not hurry.
        s_out = ctrl.get()
        if s_out["sun"] == "on" and abs(s_out["lat"]) <= 90:
            if time.monotonic() - sun_at > 60:
                sun_at = time.monotonic()
                sun_f = sun_factor(s_out["lat"], s_out["lon"], s_out["sun_night"])
                ctrl.dirty.set()     # a static sleeve must re-show dimmer
        else:
            sun_f = 1.0

        if now is not None and now.progress_ms is not None:
            prog = (now.progress_ms / 1000.0, time.monotonic(),
                    now.is_playing, (now.duration_ms or 0) / 1000.0)
            ctrl.progress = {"at": now.progress_ms, "of": now.duration_ms,
                             "playing": now.is_playing, "stamped": time.time()}
        elif now is None:
            prog = None
            ctrl.progress = {}

        if now and now.track_id != last_track \
                and time.monotonic() >= hold_until:
            # the old track's clock must not survive onto the new one when
            # the reporting tier has no progress to replace it with
            if now.progress_ms is None:
                prog = None
                ctrl.progress = {}
            if now.art_url:
                try:
                    show_sleeve(now.art_url)
                    last_track = now.track_id
                    ctrl.now_showing = {"title": now.title,
                                        "artist": now.artist,
                                        "album": now.album}
                    ctrl.shown_seq += 1
                    ctrl.journal_append({
                        "ts": int(time.time()),
                        "title": now.title, "artist": now.artist,
                        "album": now.album, "art_url": now.art_url,
                    })
                    print(f"[main] {now.artist} — {now.title}  ({now.album})")
                except Exception as exc:
                    print(f"[main] art pipeline failed: {exc}")
            else:
                print(f"[main] no art found for {now.artist} — {now.title}")
                last_track = now.track_id

        if args.once:
            if last_pre is not None:
                s = ctrl.get()
                eff = tuple(g * s["brightness"] for g in gains)
                sink.show(white_balance(last_pre, eff).tobytes(),
                          pre_wb_img=last_pre)
            break

        # ---- render until the next poll, reacting live to control ------
        poll_end = time.monotonic() + poll_s
        try:
            # a pending replay bails out of the render loop immediately
            while time.monotonic() < poll_end and ctrl.replay is None:
                s = ctrl.get()
                sl = ctrl.sleep      # snapshot: the API thread can null this
                fade = 1.0                       # sleep fade scales brightness
                if sl is not None:
                    el_min = (time.monotonic() - sl["t0"]) / 60.0
                    if el_min >= sl["minutes"]:
                        ctrl.sleep = None
                        sl = None
                        ctrl.apply({"mode": "off"})
                        s = ctrl.get()
                    else:
                        fade = max(0.0, min(1.0, 1.0 - el_min / sl["minutes"]))
                # Calibration multipliers ride on top of the config gains;
                # identity until a camera has measured the wall.
                wbc = (s["wb_r"], s["wb_g"], s["wb_b"])
                eff = tuple(g * w * s["brightness"] * fade * sun_f
                            for g, w in zip(gains, wbc))
                mode = s["mode"]

                # ---- waking up ---------------------------------------------
                # The mirror of the sleep fade: at the set time the wall comes
                # up from black over the fade, warm first, the way a sky does.
                # It only lifts a wall that is off; a wall already showing
                # something needs no sunrise.
                if s["wake_enabled"]:
                    lt = time.localtime()
                    try:
                        wh, wm = int(s["wake_time"][:2]), int(s["wake_time"][3:])
                    except ValueError:
                        wh, wm = 7, 0
                    into = (lt.tm_hour * 60 + lt.tm_min) - (wh * 60 + wm) \
                        + lt.tm_sec / 60.0
                    span = max(1.0, s["wake_fade_min"])
                    today = (lt.tm_year, lt.tm_yday)
                    if 0 <= into < span:
                        if woke_on != today and mode == "off":
                            print(f"[main] waking the wall over {span:.0f} min")
                            ctrl.apply({"mode": "art"})
                            s = ctrl.get()
                            mode = "art"
                            woke_on = today
                        if woke_on == today:
                            k = max(0.02, min(1.0, into / span))
                            # red leads, blue arrives last: warm to neutral
                            eff = (eff[0] * k,
                                   eff[1] * k * (0.55 + 0.45 * k),
                                   eff[2] * k * (0.30 + 0.70 * k))
                            need_show = True

                # A minute of silence, and only for the modes that are about a
                # track. Choosing a lamp or a clock is a decision the music
                # stopping does not get to overrule.
                idle_now = None
                if quiet_since is not None and mode in ("art", "cd") \
                        and time.monotonic() - quiet_since > 60:
                    idle = s.get("idle", "black")
                    if idle == "black":
                        mode, idle_now = "off", "black"
                    elif idle == "dim":
                        eff = tuple(g * 0.3 for g in eff)
                        idle_now = "dim"
                    elif idle == "ambient":
                        mode, idle_now = "ambient", "ambient"
                if idle_now != idle_prev:
                    # engaging or lifting the override is a repaint, or the
                    # dimmed sleeve never shows and black outlives the silence
                    idle_prev = idle_now
                    need_show = True

                if mode == "off":
                    if not blacked:
                        sink.show(black)
                        blacked = True
                    if ctrl.dirty.wait(poll_end - time.monotonic()):
                        ctrl.dirty.clear()
                        need_show = True
                    continue
                blacked = False

                if mode == "frame" and ctrl.frame_override is not None:
                    if frame_shown is not ctrl.frame_override \
                            or sl is not None:
                        f = Image.frombytes("RGB", (size, size),
                                            ctrl.frame_override)
                        sink.show(white_balance(f, eff).tobytes(),
                                  pre_wb_img=f)
                        frame_shown = ctrl.frame_override
                    wait_s = poll_end - time.monotonic()
                    if sl is not None:           # keep fading a held frame
                        wait_s = min(wait_s, 1.0)
                    if ctrl.dirty.wait(max(0.0, wait_s)):
                        ctrl.dirty.clear()
                        frame_shown = None
                    continue

                if s["match_art"] and ctrl.art_colors is None \
                        and last_pre is not None:
                    ctrl.art_colors = dominant_colors(last_pre)
                ink = (ctrl.art_colors[0]
                       if s["match_art"] and ctrl.art_colors else s["color"])

                if mode == "ticker":
                    style = s.get("ticker_style", "across")
                    key = (s["ticker_text"], ink, s["speed"],
                           s["ticker_loop"], style,
                           tuple(s["ticker_colors"]))
                    if ticker is None or key != ticker_key:
                        if style == "across":
                            ticker = Ticker(size, s["ticker_text"], color=ink,
                                            speed=s["speed"],
                                            loop=s["ticker_loop"],
                                            colors=s["ticker_colors"])
                        else:
                            ticker = Crawl(size, s["ticker_text"], color=ink,
                                           speed=s["speed"],
                                           loop=s["ticker_loop"],
                                           tilt=(style == "tilt"),
                                           colors=s["ticker_colors"])
                        ticker_key, ticker_t0 = key, time.monotonic()
                    tick = time.monotonic()
                    if ticker.done(tick - ticker_t0):
                        ctrl.apply({"mode": "art"})
                        continue
                    f = ticker.frame_at(tick - ticker_t0)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    pace(tick)
                    continue

                if mode == "nine":
                    # what the wall has worn lately, three by three
                    nine.ask(ctrl.journal_read(60))
                    img = nine.frame
                    if img is not None and (nine.built_for, s["brightness"]) != nine_shown:
                        sink.show(white_balance(img, eff).tobytes(), pre_wb_img=img)
                        nine_shown = (nine.built_for, s["brightness"])
                    elif img is None and not blacked:
                        sink.show(black)
                    if ctrl.dirty.wait(0.5):
                        ctrl.dirty.clear()
                        nine_shown = None
                    continue

                if mode == "lyrics":
                    # the words, over the sleeve, on the song's clock
                    if lyric_book.state == "done" and last_pre is not None \
                            and prog is not None:
                        key = (lyric_book.track, ink)
                        if lyric_canvas is None or key != lyric_key:
                            lyric_canvas = LyricCanvas(size, last_pre,
                                                       lyric_book.sheet,
                                                       color=ink)
                            lyric_key = key
                        tick = time.monotonic()
                        at = prog[0] + (tick - prog[1] if prog[2] else 0.0)
                        # the same anticipation the phone shows: a word is
                        # readable AS it is sung, not a beat after
                        f = lyric_canvas.frame_at(at + 0.20)
                        sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                        if ctrl.dirty.wait(0.08):
                            ctrl.dirty.clear()
                        continue
                    # nothing to sing yet: the sleeve stands in, undimmed
                    if need_show and last_pre is not None:
                        f = apply_finish(last_pre, s["finish"])
                        sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                        need_show = False
                    if ctrl.dirty.wait(0.5):
                        ctrl.dirty.clear()
                        need_show = True
                    continue

                if mode == "timer":
                    tm = ctrl.timer
                    if tm is None:
                        ctrl.apply({"mode": "clock"})
                        continue
                    key = (ink, s["color2"])
                    if countdown is None or key != countdown_key:
                        countdown = Countdown(size, color=ink,
                                              accent=s["color2"])
                        countdown_key = key
                    left = tm["end"] - time.monotonic()
                    if left <= -60:
                        # a minute of light is the whole alarm; then put back
                        # whatever the wall was doing before the timer took it
                        ctrl.timer = None
                        ctrl.apply({"mode": tm["ret"]})
                        continue
                    f = countdown.frame_at(left, tm["total"])
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    # the ring moves a pixel every few seconds; the pulse
                    # needs to breathe. Wait shorter only when pulsing.
                    if ctrl.dirty.wait(0.15 if left <= 0 else 0.5):
                        ctrl.dirty.clear()
                    continue

                if mode == "clock":
                    key = (ink, s["clock_24h"])
                    if clock is None or key != clock_key:
                        clock = Clock(size, color=ink,
                                      twenty_four=s["clock_24h"])
                        clock_key = key
                    f = clock.frame_at(0.0)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    if ctrl.dirty.wait(0.5):
                        ctrl.dirty.clear()
                    continue

                if mode == "clip" and ctrl.clip is not None:
                    c = ctrl.clip
                    tick = time.monotonic()
                    if tick >= clip_next:
                        frame = c["frames"][clip_i % len(c["frames"])]
                        f = Image.frombytes("RGB", (size, size), frame)
                        sink.show(white_balance(f, eff).tobytes(),
                                  pre_wb_img=f)
                        clip_i += 1
                        clip_next = tick + 1.0 / c["fps"]
                    if ctrl.dirty.wait(max(0.0, clip_next
                                           - time.monotonic())):
                        ctrl.dirty.clear()
                    continue

                if mode == "ambient":
                    c1, c2 = s["color"], s["color2"]
                    if s["match_art"] and ctrl.art_colors:
                        c1, c2 = ctrl.art_colors[0], ctrl.art_colors[-1]
                    key = (s["effect"], c1, c2, s["speed"])
                    if ambient is None or key != amb_key:
                        ambient = Ambient(size, *key)
                        amb_key, amb_t0 = key, time.monotonic()
                    tick = time.monotonic()
                    f = ambient.frame_at(tick - amb_t0)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    pace(tick)
                    continue

                if mode == "cd" and animator is not None:
                    if animator.rpm != s["rpm"]:
                        animator.rpm = s["rpm"]
                    tick = time.monotonic()
                    # Between polls the phone is not going to tell us again,
                    # so run the clock forward from the last thing it said.
                    at, frac = None, None
                    if prog is not None:
                        at = prog[0] + (tick - prog[1] if prog[2] else 0.0)
                        if prog[3] > 0:
                            frac = min(1.0, at / prog[3])
                    f = animator.frame_at(tick - t0, progress_s=at, fraction=frac)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    pace(tick)
                    continue

                # static sleeve ("art", or "cd" before any art has arrived)
                if need_show and last_pre is not None:
                    if (id(last_pre), s["finish"]) != fin_key:
                        fin_img = apply_finish(last_pre, s["finish"])
                        fin_key = (id(last_pre), s["finish"])
                    sink.show(white_balance(fin_img, eff).tobytes(),
                              pre_wb_img=fin_img)
                    need_show = False
                wait_s = poll_end - time.monotonic()
                if sl is not None:               # keep fading while static
                    wait_s = min(wait_s, 1.0)
                    need_show = True
                if ctrl.dirty.wait(max(0.0, wait_s)):
                    ctrl.dirty.clear()
                    need_show = True
        except KeyboardInterrupt:
            print("\n[main] bye")
            break


if __name__ == "__main__":
    main()
