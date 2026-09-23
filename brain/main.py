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
import threading
import time

if sys.version_info < (3, 11):
    sys.exit("python >= 3.11 required (tomllib) — found "
             + ".".join(map(str, sys.version_info[:3])))
import tomllib

import numpy as np
from PIL import Image

from .art.disc import DiscAnimator
from .art.effects import Ambient
from .art.fetch import fetch_art
from .art.lyrics import LyricBook, LyricCanvas
from .playback import ReplayHold
from .rest import resolve_rest
from .art.nine import NineBuilder
from . import halo as halo_mod
from . import homekit as homekit_mod
from .features import Features
from .scrobble import Scrobbler
from .shelf import Shelf
from .posters import Posters, PosterSource
from .imagine import Imaginer
from .nowplaying.airplay import AirPlaySource
from .nowplaying.receiver import Receiver
from .games.host import GameHost
from .games import (wordle, sudoku, spellingbee, letterboxed, connections, strands, crossword,   # noqa: F401
                    contexto, reaction, whistlebird, pictures, heardle, quiz, twentyq, pictionary,
                    arcade)                                                                        # each registers itself
from .art.mark import owned_mark
from .art import pipeline as art_pipeline
from .art.pipeline import apply_finish, dominant_colors, prepare, white_balance
from .art.text_modes import Clock, Countdown, Crawl, Ticker
from .control import ControlState, serve as serve_control
from .nowplaying import SourceChain
from .nowplaying.ears import EarsSource
from .nowplaying.knock import KnockEar
from .nowplaying.teach import Library, Teacher
from .ask import Asker
from .show import Shower
from .voice import Voice
from .voice.wake import WakeWord
from .voice.listen import Transcriber
from .art.horizon import OPEN_S as VOICE_OPEN_S
from .art.weather import WeatherFace
from .weather import Weather
from .nowplaying.applemusic import AppleMusicSource
from .nowplaying.applemusic_account import AppleMusicAccountSource, configured as account_configured
from .nowplaying.lastfm import LastfmSource
from .nowplaying.listenbrainz import ListenBrainzSource
from .nowplaying.macmedia import MacMediaSource
from .nowplaying.pushed import PushedSource
from .nowplaying.spotify import SpotifySource
from .services import Services
from .tuning import Tuning
from .video.player import VideoPlayer
from .wall import Wall
from .sinks.mac_preview import MacPreviewSink
from .sinks.pi_renderer import PiRendererSink


def load_config(path: str) -> dict:
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def make_sink(cfg: dict, override: str | None = None, wall=None):
    kind = override or cfg["sink"]["type"]
    if kind == "pi":
        return PiRendererSink(cfg["sink"].get("fifo", "/tmp/album-frame.fifo"),
                              wall=wall)
    if kind == "preview":
        return MacPreviewSink(cfg["sink"].get("preview_dir", "preview_out"))
    raise ValueError(f"unknown sink type: {kind}")


DEFAULT_ORDER = ["phone", "airplay", "applemusic", "spotify", "lastfm", "listenbrainz", "ears"]


def build_sources(cfg: dict, ctrl):
    """The chain, first answer wins:
      phone        what the app posts to /push (no Mac needed)
      applemusic   on a Mac: Music.app, then anything else the Mac plays
                   (media-control), then the account view via the helper;
                   on the Pi: the account view straight from MusicKit
      spotify      the API, for any device; tokens arrive from the phone
      lastfm       Spotify, Tidal and Deezer reporting through one account
      listenbrainz the open ledger; reading it needs no key at all
      ears         the wall's own microphone, for anything out loud; last
                   in line, but the chain lets a source that can hear music
                   playing outrank one that only remembers a paused song
    Every adapter is built whether or not it has its details yet: the phone
    hands them over later (POST /services) and the adapter starts answering
    with no restart. config.toml's list is the order of preference; anything
    it leaves out still comes after, so a service connected from the phone
    always has somewhere to be."""
    store = Services(cfg)
    ctrl.services_store = store
    order = [str(n) for n in cfg.get("nowplaying", {}).get("adapters", DEFAULT_ORDER)]
    order = ["ears" if n == "acoustid" else n for n in order]   # the ear's old name
    order += [n for n in DEFAULT_ORDER if n not in order]
    sources = []
    for name in order:
        if name == "phone":
            ctrl.pushed = PushedSource()
            sources.append(ctrl.pushed)
        elif name == "airplay":
            # the wall as an AirPlay receiver: shairport-sync's metadata pipe
            # (docs/AIRPLAY.md). Built whether or not the pipe exists yet.
            features = getattr(ctrl, "features", None)
            if features is not None and not features.on("airplay"):
                continue
            acfg = cfg.get("airplay", {})
            ctrl.airplay = AirPlaySource(
                pipe=str(acfg.get("pipe", "/tmp/shairport-sync-metadata")),
                port=int(cfg.get("control", {}).get("port", 8788)),
                host=str(acfg.get("host", "")) or None).start()
            sources.append(ctrl.airplay)
            # the receiver itself: shairport-sync, run and watched by the brain
            # (pi/install-airplay.sh puts it under ~/opt without root)
            ctrl.airplay_receiver = Receiver(ctrl.airplay.pipe, settings=ctrl.get,
                                             binary=str(acfg.get("binary", "")) or None).start()
            print("[main] airplay: " + ("the receiver starts as " + repr(ctrl.get().get("airplay_name", "Wall"))
                                        if ctrl.get().get("airplay_receiver", True) else "the receiver is off"))
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
        elif name == "ears":
            ear = EarsSource(store.get("ears", "device")
                             or store.get("acoustid", "device") or "auto",
                             on_change=ctrl.nudge)
            ctrl.ears = ear
            sources.append(ear)
            st = ear.status()
            print(f"[main] ears: {'opening the microphone' if st['tools'] else st['problem']}")
        else:
            print(f"[main] adapter {name!r} unknown — skipping")
    if not sources:
        sys.exit("[main] no now-playing sources configured")
    # posters: right after the Mac, so a show it is watching gets its poster
    # before the ears or a scrobbler get a say. Off with [features] posters.
    ctrl.posters = None
    features = getattr(ctrl, "features", None)
    if ctrl.apple is not None and (features is None or features.on("posters")):
        ctrl.posters = Posters(store.get("tmdb", "api_key"))
        sources.insert(sources.index(ctrl.apple) + 1, PosterSource(ctrl.apple, ctrl.posters))
        print("[main] posters: " + ("TMDB key set; a show on the Mac gets its poster"
                                    if ctrl.posters.ready
                                    else "no TMDB key yet; set one from the phone"))
    return sources


def _is_shown(now, last_track, showing) -> bool:
    """Is this the song already on the wall? By id first; by name when two
    sources report the same song under different ids."""
    if now.track_id == last_track:
        return True
    if not showing:
        return False
    def plain(x):
        return (x or "").strip().lower()
    return plain(now.title) == plain(showing.get("title")) \
        and plain(now.artist) == plain(showing.get("artist"))


class _Poller(threading.Thread):
    """Asks the source chain on its own thread. A poll can take seconds when
    a source is slow (the Mac's account helper, a scrobbler across the
    internet), and for as long as the render loop made that call itself the
    wall froze for the duration: an ambient face stuttering every two
    seconds, the phone's requests queueing behind a lookup. Now the loop
    only ever reads `latest`. `wake` (ctrl.repoll) brings the next poll
    forward, which is what a phone push or the ear's hit does; `news`
    (ctrl.news) tells the loop an answer is in."""

    def __init__(self, source, interval, wake, news):
        super().__init__(daemon=True, name="poll")
        self.source, self.interval, self.wake, self.news = source, interval, wake, news
        self.latest = None
        self.asked_at = None
        # The answer with the moment it was true, both clocks, in one tuple
        # so the loop reads them together. The song's position is only right
        # at that moment; stamped with the loop's own time on a later pass
        # it went backwards by the age of the answer, and the lyrics and the
        # spinning record stepped back with it every couple of seconds.
        self.answer = (None, time.monotonic(), time.time())

    def run(self):
        while True:
            try:
                now = self.source.get_current()
            except Exception as exc:
                print(f"[poll] {exc}")
                now = None
            self.latest, self.asked_at = now, time.monotonic()
            self.answer = (now, self.asked_at, time.time())
            self.news.set()
            self.wake.wait(self.interval)
            self.wake.clear()


class _FrameTee:
    """Wraps the sink so the control API always has the current frame
    (pre-white-balance when available — that's what the phone previews)."""

    def __init__(self, sink, ctrl, size, halo=None):
        self._sink, self._ctrl, self._size = sink, ctrl, size
        self._halo = halo

    def _open(self, raw: bytes, k: float, ink) -> bytes:
        """The frame with only a band around the middle showing, k of the
        way open, and a line of ink at the band's edges."""
        side = int(round((len(raw) / 3) ** 0.5))
        f = np.frombuffer(raw, dtype=np.uint8).reshape(side, side, 3).copy()
        half = max(1, int(round(k * side / 2)))
        mid = side // 2
        f[:max(0, mid - half)] = 0
        f[min(side, mid + half):] = 0
        col = np.array(ink, dtype=np.float32) * (1.0 - k)
        for y in (mid - half - 1, mid + half):
            if 0 <= y < side:
                f[y] = np.maximum(f[y], col.astype(np.uint8))
        return f.tobytes()

    def show(self, rgb888: bytes, pre_wb_img=None):
        # a face opening from the voice's line: the frames after a command
        # are unmasked from the middle outwards for a moment (art/horizon.py)
        settings = self._ctrl.get()
        tr = getattr(self._ctrl, "transition", None)
        if tr is not None and (settings["mode"] in ("off", "timer")
                               or getattr(self._ctrl, "display_mode", None) in ("off", "timer")):
            # Opening a black frame adds coloured edge lines. Off paints only
            # once, so those lines could otherwise remain on a resting wall.
            # A timer/alarm also needs its unobscured face immediately.
            self._ctrl.transition = None
            tr = None
        if tr is not None:
            kind, t0, ink = tr
            k = (time.monotonic() - t0) / VOICE_OPEN_S
            if k >= 1.0:
                self._ctrl.transition = None
            else:
                rgb888 = self._open(rgb888, k, ink)
                if pre_wb_img is not None:
                    # a PIL image from the sleeve faces, a numpy array from the
                    # animated ones: masked the same, handed back as it came
                    arr = np.asarray(pre_wb_img)
                    masked = np.frombuffer(self._open(arr.tobytes(), k, ink),
                                           dtype=np.uint8).reshape(arr.shape)
                    pre_wb_img = (masked if isinstance(pre_wb_img, np.ndarray)
                                  else Image.fromarray(masked))
                self._ctrl.dirty.set()               # keep the frames coming
        self._ctrl.last_frame = (pre_wb_img.tobytes()
                                 if pre_wb_img is not None else rgb888)
        # every mode reaches the wall through here, so the halo hangs off this
        # one call and follows album art, video and effects alike
        if self._halo is not None and pre_wb_img is not None:
            self._halo.show(pre_wb_img)
        self._sink.brightness = settings["panel_brightness"]
        if self._ctrl.tuning is not None:
            self._sink.dither = self._ctrl.tuning.get("dither")
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
    # How many panels, in what order, which way up. One panel is a wall of
    # one: everything below sizes itself from wall.width either way.
    wall = Wall.from_config(cfg)
    if wall.width != wall.height:
        sys.exit(
            f"[main] the wall is {wall.width}x{wall.height} and the brain "
            "renders squares: every face it draws, from a sleeve to the "
            "clock, is a square.\n"
            "        A single chain (3x1) is for bring-up and QA: run the "
            "renderer and scripts/panel_qa.py against it, and start the "
            "brain when the wall is square.")
    size = wall.width
    # Every knob that decides what the LEDs do, in one store: the gains, the
    # dark end, the sharpening, the renderer's own launch flags. config.toml
    # seeds it; the phone's tuning page moves it from there.
    tune = Tuning(cfg)
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
    }, frame_len=size * size * 3, wall=wall)
    # [features] in config.toml: a switch per feature, asked at the moment a
    # feature would act, so one thing can be tested at a time
    ctrl.features = Features(cfg)
    source = SourceChain(build_sources(cfg, ctrl))
    ctrl.source = source
    poller = _Poller(source, poll_s, wake=ctrl.repoll, news=ctrl.news)
    poller.start()
    if args.once:
        ctrl.news.wait(20)               # one pass wants an answer to show
    # a link from the phone: fetched and decoded on its own threads
    ctrl.video = VideoPlayer(size, ctrl.dirty, on_media=ctrl.video_media,
                             unsharp_radius=tune.get("unsharp_radius"),
                             unsharp_percent=tune.get("unsharp_percent"))
    ctrl.tuning = tune
    tune.video = ctrl.video
    tune.ears = ctrl.ears          # the Hearing knobs land on the ear
    tune.apply()
    serve_control(ctrl, int(cfg.get("control", {}).get("port", 8788)))
    # the Home app's view of the wall, on its own thread; None when [homekit]
    # is off, and the brain runs the same either way
    ctrl.homekit = (homekit_mod.from_config(cfg, ctrl)
                    if ctrl.features.on("homekit") else None)
    # the ear's records, written to ListenBrainz; its own thread, its own queue
    ctrl.scrobbler = (Scrobbler.from_config(cfg, ctrl).start()
                      if ctrl.features.on("scrobble") else None)
    if ctrl.scrobbler is not None:
        print("[main] scrobble: " + ("token set, following the ear"
                                     if ctrl.scrobbler.configured
                                     else "no ListenBrainz token yet; set one from the phone"))
    # the shelf: the Discogs collection, for the corner mark and the pressing
    ctrl.shelf = None
    if ctrl.features.on("shelf"):
        ctrl.shelf = Shelf(ctrl, token=ctrl.services_store.get("discogs", "token"),
                           user=ctrl.services_store.get("discogs", "user")).start()
        st = ctrl.shelf.status()
        print("[main] shelf: " + (f"{st['releases']} releases for {st['user']}"
                                  if ctrl.shelf.configured
                                  else "no Discogs token yet; set one from the phone"))
    # the wall's own song library, asked before Shazam, and its teacher
    if ctrl.ears is not None and ctrl.features.on("teach"):
        lib = Library(min_score=tune.get("teach_match_score"))
        ctrl.ears._library_kept = lib
        ctrl.ears.library = lib if tune.get("teach") else None
        ctrl.ears.teacher = Teacher(lib, ctrl.ears, by_ear=tune.get("teach_by_ear"))
        st = lib.status()
        print(f"[main] teach: {st['songs']} songs, {st['landmarks']} landmarks known"
              f"{'' if tune.get('teach') else ' (lookup off by the knob)'}")
    # the switch: two knocks on the frame, or a whistle, heard by the ear
    if ctrl.ears is not None and ctrl.features.on("knock"):
        ctrl.ears.knocks = KnockEar(ctrl, knock=tune.get("knock"),
                                    sensitivity_db=tune.get("knock_sensitivity"),
                                    whistle=tune.get("whistle"))
        print("[main] knock: two knocks or a whistle switch the wall "
              f"(knock {'on' if tune.get('knock') else 'off'}, "
              f"whistle {'on' if tune.get('whistle') else 'off'})")
    # asking: a question in words, Claude's answer on the panel
    ctrl.asker = None
    if ctrl.features.on("ask"):
        ctrl.asker = Asker(ctrl, api_key=ctrl.services_store.get("claude", "api_key"),
                           model=str(cfg.get("ask", {}).get("model", "claude-opus-5")),
                           workspace=ctrl.services_store.get("claude", "workspace"))
        print("[main] ask: " + ("key set" if ctrl.asker.ready
                                else "no Claude key yet; set one from the phone"))
    # show me, play me, and the earworm finder: by voice or from the phone
    ctrl.shower = Shower(ctrl, asker=ctrl.asker,
                         google_key=ctrl.services_store.get("google", "api_key"),
                         google_cx=ctrl.services_store.get("google", "cx")) \
        if ctrl.features.on("show") else None
    # games: one at a time, the wall the board and the phone the hand
    ctrl.games = GameHost(ctrl) if ctrl.features.on("games") else None
    if ctrl.games is not None:
        print(f"[main] games: {', '.join(g['title'] for g in ctrl.games.listing())}")
    # a picture from words: Claude writes the prompt, an image model draws it
    ctrl.imaginer = None
    if ctrl.features.on("imagine"):
        icfg = cfg.get("imagine", {})
        store = ctrl.services_store
        ctrl.imaginer = Imaginer(
            ctrl, shower=ctrl.shower or Shower(ctrl, asker=ctrl.asker), asker=ctrl.asker,
            provider=store.get("images", "provider") or str(icfg.get("provider", "openai")),
            api_key=store.get("images", "api_key"),
            openai_model=str(icfg.get("openai_model", "gpt-image-2")),
            google_model=str(icfg.get("google_model", "imagen-4.0-ultra-generate-001")),
            quality=store.get("images", "quality") or str(icfg.get("quality", "medium")))
        if store.get("images", "model"):
            ctrl.imaginer.configure(model=store.get("images", "model"))
        st = ctrl.imaginer.status()
        print(f"[main] imagine: {st['provider']} {st['model']} " + ("(key set)" if st["ready"]
                                                                   else "(no key yet; set one from the phone)"))
    # the weather, kept fresh for its face and for the phone
    ctrl.weather = Weather(ctrl).start() if ctrl.features.on("weather") else None
    if ctrl.weather is not None:
        print("[main] weather: " + (f"for {ctrl.weather.where()}" if ctrl.weather.where()
                                    else "no place set yet; name one from the phone"))
    weather_face = None
    # the voice: the wake word, then the words, on the ear's stream
    ctrl.voice = None
    if ctrl.ears is not None and ctrl.features.on("voice"):
        vcfg = cfg.get("voice", {})
        from .voice.wake import saved_choice, saved_threshold, save_threshold, threshold_for
        kept = saved_choice()
        name = kept or str(vcfg.get("wake_word", "hey_jarvis"))
        if not name.startswith("own:") and saved_threshold(name) is None:
            save_threshold(name, float(tune.get("wake_threshold")))   # turned before each word kept its own
        wake = WakeWord(name, threshold=threshold_for(name))
        if kept and not wake.loaded:
            print(f"[main] voice: the kept wake word {kept!r} will not load ({wake.problem}); using the config's")
            name = str(vcfg.get("wake_word", "hey_jarvis"))
            wake = WakeWord(name, threshold=threshold_for(name))
        listener = Transcriber(size="base" if tune.get("speech_base") else "tiny")
        ctrl.voice = Voice(ctrl, wake, listener, asker=ctrl.asker, size=size,
                           teacher=getattr(ctrl.ears, "teacher", None), shower=ctrl.shower)
        ctrl.voice.configure(on=tune.get("wake"))
        ctrl.ears.voice = ctrl.voice
        if abs(wake.threshold - float(tune.get("wake_threshold"))) > 1e-3:
            tune.update({"wake_threshold": wake.threshold})          # the tuning page shows the word in use
        print("[main] voice: " + (f"listening for {wake.label!r}" if wake.loaded
                                  else f"no wake word ({wake.problem})"))
    halo = halo_mod.from_config(cfg)
    sink = _FrameTee(make_sink(cfg, args.sink, wall), ctrl, size, halo=halo)
    if halo is not None:
        print(f"[main] halo: {halo.count} LEDs")

    print(f"[main] adapters: {[s.name for s in source.sources]}, "
          f"wall {wall}, poll {poll_s:.0f}s, "
          f"gains R{tune.gains[0]:.2f}/G{tune.gains[1]:.2f}/B{tune.gains[2]:.2f}")

    if ctrl.features.on("sting") and not args.once:
        # The logo, at boot, off the loop's thread: the first time at a wall
        # size the film is decoded and cut, which takes the Pi twenty
        # seconds (kept on disk after that), and the renderer takes a few
        # seconds after its own start before it listens, and a clip's early
        # frames are not kept for it the way a still picture is. So a thread
        # waits for the renderer to attach, has the frames made, and plays.
        def boot_sting():
            attached = getattr(getattr(sink, "_sink", None), "attached", None)
            for _ in range(40):
                if attached is None or attached():
                    break
                time.sleep(0.25)
            try:
                ctrl.play_sting()
            except Exception as exc:
                print(f"[main] sting: {exc}", flush=True)
        threading.Thread(target=boot_sting, name="sting", daemon=True).start()

    last_track, last_pre = None, None
    animator, t0 = None, time.monotonic()
    ambient, amb_key, amb_t0 = None, None, time.monotonic()
    blacked, need_show = False, False
    fin_key, fin_img, frame_shown = None, None, None
    replay_hold = ReplayHold()
    quiet_since = None               # when the music stopped, for idle
    # Where the song is, and when we last heard that. The record turns from
    # this rather than from the wall clock, so a seek seeks the record.
    prog = None                      # (seconds_in, monotonic_at, playing, total)
    now, now_at, now_wall = None, time.monotonic(), time.time()   # the poll and its moment
    ticker, ticker_key, ticker_t0 = None, None, 0.0
    countdown, countdown_key = None, None
    nine = NineBuilder(size)
    nine_shown = None
    lyric_book = LyricBook()
    ctrl.lyric_book = lyric_book
    lyric_canvas, lyric_key = None, None
    routine_eff = None
    clock, clock_key = None, None
    clip_i, clip_next, clip_id = 0, 0.0, None
    now, video_shown = None, None
    black = bytes(size * size * 3)
    idle_prev = None                 # which idle override is currently applied
    disc_key = None                  # (pressing, sleeve) the disc was built from

    def show_sleeve(art_url, owned=False):
        """The one path that puts a sleeve on the wall: fetch, prepare, arm
        the disc animator, extract colours. Callers add their bookkeeping.
        `owned` stamps the shelf's mark into the corner: you have this on
        vinyl, and every face that shows the sleeve shows it."""
        nonlocal last_pre, animator, t0, need_show
        pre = prepare(
            fetch_art(art_url), size,
            unsharp_radius=tune.get("unsharp_radius"),
            unsharp_percent=tune.get("unsharp_percent"),
        )
        if owned and tune.get("shelf_mark"):
            pre = owned_mark(pre, size)
        last_pre = pre
        animator = build_disc(pre)
        # what each finish would do to this sleeve, for the phone to show
        ctrl.finish_base = pre
        t0 = time.monotonic()
        need_show = True
        ctrl.art_colors = dominant_colors(pre)

    def song_key(np_):
        """The name the phone knows a song by: artist and title, folded the
        same way on both sides. The phone cannot know this wall's track id
        (an adapter's own string), so a pressing arrives keyed by name."""
        if np_ is None:
            return ""
        def fold(t):
            return " ".join((t or "").lower().split())
        return fold(np_.artist) + "|" + fold(np_.title)

    def build_disc(pre):
        """The record for the spin face. The phone sends the pressing it drew
        for this song; when it is for the song that is on, the wall turns
        that, so the wall and the room's deck play the same record."""
        p = ctrl.pressing
        key = song_key(now)
        if ctrl.get()["spin_face"] == "pressing" \
                and p is not None and (not p[0] or not key or p[0] == key):
            try:
                img = Image.frombytes("RGB", (size, size), p[1])
                print(f"[main] spin: the phone's pressing for {p[0] or 'this song'}")
                return DiscAnimator(img, size, rpm=ctrl.get()["rpm"], pressed=True)
            except Exception:
                pass
        return DiscAnimator(pre, size, rpm=ctrl.get()["rpm"])

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
        ctrl.loop_beat = time.monotonic()      # /health: the loop is alive
        # ---- phone asked to re-show something from the journal ----------
        if ctrl.replay is not None:
            entry, ctrl.replay = ctrl.replay, None
            try:
                owned = (ctrl.shelf.note_playing(entry.get("album", ""), entry.get("artist", ""))
                         if ctrl.shelf is not None else None)
                show_sleeve(entry["art_url"], owned=owned is not None)
                ctrl.now_showing = {"title": entry.get("title", "?"),
                                    "artist": entry.get("artist", "?"),
                                    "album": entry.get("album", "")}
                ctrl.shown_seq += 1
                replay_hold.arm(now, time.monotonic())
                ctrl.replay_active = True
                print(f"[main] replay: {entry.get('artist')} — "
                      f"{entry.get('title')}")
            except Exception as exc:
                ctrl.replay_active = replay_hold.active
                print(f"[main] replay failed: {exc}")

        # ---- poll now-playing; rebuild art state on track change --------
        # Not while a video is on: a poll can cost two seconds, and a
        # picture that freezes for two seconds every five is not a video.
        # The song is still there when the video ends.
        # The answer comes from the poller's thread, so a slow source never
        # stalls the picture. Not while a video is on: the song is still
        # there when the video ends.
        ctrl.news.clear()
        if not (ctrl.video is not None and ctrl.video.busy
                and ctrl.get()["mode"] == "video"):
            now, now_at, now_wall = poller.answer
            # A paused source keeps the wall only when it is the song the
            # wall is already on: the thing that just stopped. A phone left
            # paused on some other song while a record played is not news;
            # when the record ends the wall goes quiet the way it does for
            # everything else, and the idle face follows in its own time.
            if now is not None and not now.is_playing and last_track is not None \
                    and not _is_shown(now, last_track, ctrl.now_showing):
                now = None

        ctrl.playing_identity = ({"title": now.title, "artist": now.artist, "album": now.album}
                                 if now is not None else {})
        resume, ctrl.resume_music = ctrl.resume_music, False
        if replay_hold.release(now, time.monotonic(), resume) or resume:
            # Replay replaced the pixels, even if the music never changed ID.
            # Invalidate the artwork cache so that same song is restored too.
            last_track = None
            ctrl.replay_active = False

        # Silence is a state worth having an opinion about. A wall left on a
        # frozen sleeve all night is a different object from one that quietly
        # goes dark, so this is the owner's call, not ours.
        # Music that can be shown resets the quiet clock. A playing answer
        # with no sleeve (a video on the Mac) keeps the last sleeve up but
        # is quiet for this purpose, so the idle face still follows.
        if now is not None and now.is_playing and now.art_url:
            quiet_since = None
        elif quiet_since is None:
            quiet_since = time.monotonic()
        ctrl.quiet_since = quiet_since         # /health: how long the room has been quiet
        # the teacher watches what the other sources name while the ear listens
        teacher = getattr(ctrl.ears, "teacher", None) if ctrl.ears is not None else None
        if teacher is not None:
            try:
                teacher.observe(now)
            except Exception as exc:
                print(f"[main] teach: {exc}", flush=True)

        if now is not None and now.progress_ms is not None:
            # stamped with the poll's own moment, not this pass's: the loop
            # comes round more often than the poller answers
            prog = (now.progress_ms / 1000.0, now_at,
                    now.is_playing, (now.duration_ms or 0) / 1000.0)
            ctrl.progress = {"at": now.progress_ms, "of": now.duration_ms,
                             "playing": now.is_playing, "stamped": now_wall}
        elif now is not None and not now.is_playing:
            # A pause with an unavailable position still stops the last clock.
            if prog is not None:
                at = prog[0] + (now_at - prog[1] if prog[2] else 0)
                prog = (max(0, at), now_at, False, prog[3])
                ctrl.progress = {"at": max(0, at) * 1000, "of": prog[3] * 1000,
                                 "playing": False, "stamped": now_wall}
        elif now is None:
            prog = None
            ctrl.progress = {}

        # the words: asked for once per track, the moment it is known, so
        # the lyrics face has them ready when it is chosen. The book fetches
        # off the loop and says "none" for a song nobody has synced.
        if now is not None and now.track_id:
            lyric_book.ask(now.track_id, now.artist, now.title, now.album,
                           (now.duration_ms or 0) / 1000.0 or None)

        if now and now.track_id != last_track \
                and not replay_hold.active:
            # the old track's clock must not survive onto the new one when
            # the reporting tier has no progress to replace it with
            if now.progress_ms is None:
                prog = None
                ctrl.progress = {}
            # the shelf: is this album on it? The pressing goes to the phone
            # and the sleeve gets the corner mark
            owned = (ctrl.shelf.note_playing(now.album, now.artist)
                     if ctrl.shelf is not None else None)
            if owned is not None:
                print(f"[main] on the shelf: {owned.get('year') or ''} {owned.get('label')} "
                      f"{owned.get('catno')}".strip())
            if now.art_url:
                try:
                    show_sleeve(now.art_url, owned=owned is not None)
                    last_track = now.track_id
                    ctrl.now_showing = {"title": now.title,
                                        "artist": now.artist,
                                        "album": now.album}
                    ctrl.shown_seq += 1
                    ctrl.journal_append({
                        "ts": int(time.time()),
                        "title": now.title, "artist": now.artist,
                        "album": now.album, "art_url": now.art_url,
                        **({"kind": "show"} if now.track_id.startswith("show:") else {}),
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
                art_pipeline.PANEL_CAP = int(s["panel_brightness"])
                eff = tuple(g * s["brightness"] for g in tune.gains)
                sink.show(white_balance(last_pre, eff).tobytes(),
                          pre_wb_img=last_pre)
            break

        # ---- render until the next poll, reacting live to control ------
        # At least a breath of rendering between polls, whatever the poll
        # interval says. A poll can cost a second or two (a helper process,
        # a lookup over the network); with a shorter interval than that the
        # loop never rested, the Pi sat at a pegged core, and the phone's
        # own requests started timing out behind it.
        poll_end = time.monotonic() + max(1.5, poll_s)
        try:
            # a pending replay bails out of the render loop immediately
            while time.monotonic() < poll_end and ctrl.replay is None \
                    and not ctrl.news.is_set():
                routine = ctrl.tick_routines()
                s = ctrl.get()
                sl = ctrl.sleep
                fade = routine["sleep_factor"]
                sun_f = routine["sun_factor"]
                waking = routine["wake_active"]
                current_eff = (round(fade * sun_f, 5), round(routine["wake_factor"], 5))
                if current_eff != routine_eff:
                    need_show = True
                    frame_shown = None
                    routine_eff = current_eff
                # Calibration multipliers ride on top of the config gains;
                # identity until a camera has measured the wall. The colour
                # part is settled first and kept under 1.0 by scaling all
                # three together, so a correction can be dialled back
                # without a channel blowing its top; brightness then scales
                # all three equally. Capping each channel on its own was
                # the cyan wall of 2026-09-15: the three multipliers had
                # been pushed above 1.0 from the tuning page, each clipped
                # to 1.0, and the measured gains under them were silently
                # switched off. Scaled together, only their ratio counts.
                # the panel's cap decides its steps; the nearest-colour pick
                # in the pipeline has to know it (see art/pipeline.py)
                art_pipeline.PANEL_CAP = int(s["panel_brightness"])
                wbc = (s["wb_r"], s["wb_g"], s["wb_b"])
                colour = tuple(g * w for g, w in zip(tune.gains, wbc))
                over = max(colour)
                if over > 1.0:
                    colour = tuple(c / over for c in colour)
                eff = tuple(c * s["brightness"] * fade * sun_f for c in colour)
                if waking:
                    k = routine["wake_factor"]
                    eff = (eff[0] * k, eff[1] * k * (0.55 + 0.45 * k),
                           eff[2] * k * (0.30 + 0.70 * k))
                mode = s["mode"]
                if mode != "ticker":
                    # A completed once-only message must start again when the
                    # person returns to it, even when its text is unchanged.
                    ticker, ticker_key = None, None

                # Quiet and away only override the output. Persisting Off
                # here used to cancel timers and could revive a manually
                # switched-off wall when the phone returned.
                rest_tick = time.monotonic()
                ages = [age for sc in source.sources
                        if (age := getattr(sc, "phone_age", None)) is not None]
                if ctrl.last_client is not None:
                    ages.append(max(0.0, rest_tick - ctrl.last_client))
                rest = resolve_rest(mode, idle=s.get("idle", "black"),
                                    quiet_for=None if quiet_since is None else rest_tick - quiet_since,
                                    away=s.get("away", "stay"),
                                    presence_age=min(ages) if ages else None,
                                    playing=bool(now and now.is_playing),
                                    waking=waking, sleeping=sl is not None,
                                    weather_available=ctrl.weather is not None)
                mode = rest.mode
                eff = tuple(g * rest.brightness for g in eff)
                ctrl.idle_now, ctrl.away_now = rest.idle, rest.away
                ctrl.display_mode = mode
                rest_key = (rest.idle, rest.away, mode)
                if rest_key != idle_prev:
                    # engaging or lifting the override is a repaint, or the
                    # dimmed sleeve never shows and black outlives the silence.
                    # Still-frame faces cache their own last paint; invalidating
                    # only need_show leaves drawings/grids black after Away,
                    # or leaves a timer's final image on a restored drawing.
                    idle_prev = rest_key
                    need_show = True
                    frame_shown = None
                    nine_shown = None

                # An answer can outlive the action that opened it. Resolve
                # power and routine priority first, so an existing answer
                # cannot cover Off, automatic darkness, or a new timer/alarm.
                # Still advance a hidden answer so it expires normally and
                # cannot leave the voice permanently busy behind a dark wall.
                voice = ctrl.voice
                if voice is not None and voice.state != "idle":
                    tick = time.monotonic()
                    vf = voice.frame(tick, size)
                    if vf is not None and mode not in ("off", "timer"):
                        sink.show(white_balance(vf, eff).tobytes(), pre_wb_img=vf)
                        blacked = False
                        need_show = True
                        frame_shown = None
                        nine_shown = None
                        pace(tick)
                        continue

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
                    if frame_shown != (id(ctrl.frame_override), s["finish"]) \
                            or sl is not None or waking:
                        f = Image.frombytes("RGB", (size, size),
                                            ctrl.frame_override)
                        # (the panel's floor is applied to everything, in
                        # white_balance, so a design needs nothing special)
                        ctrl.finish_base = f
                        # a pushed picture takes the finish too, as a sleeve does
                        f = apply_finish(f, s["finish"])
                        # a design's dim greys are flat tones on purpose: the hard lift
                        sink.show(white_balance(f, eff, hard=True).tobytes(),
                                  pre_wb_img=f)
                        frame_shown = (id(ctrl.frame_override), s["finish"])
                    wait_s = poll_end - time.monotonic()
                    if sl is not None or waking: # keep fading a held frame
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
                           tuple(s["ticker_colors"]),
                           getattr(ctrl, "ticker_revision", 0))
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
                        # The app can select Ticker again before the next mode
                        # snapshot; retire this completed run immediately.
                        ticker, ticker_key = None, None
                        continue
                    f = ticker.frame_at(tick - ticker_t0)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    pace(tick)
                    continue

                if mode == "nine":
                    # what the wall has worn lately, three by three
                    nine.ask(ctrl.journal_read(60))
                    img = nine.frame
                    if img is not None:
                        ctrl.finish_base = img
                    if img is not None and (nine.built_for, s["brightness"], s["finish"], current_eff) != nine_shown:
                        shown = apply_finish(img, s["finish"])
                        sink.show(white_balance(shown, eff).tobytes(), pre_wb_img=shown)
                        nine_shown = (nine.built_for, s["brightness"], s["finish"], current_eff)
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
                        # a word should be readable AS it is sung, not a beat
                        # after; how far ahead is yours to set
                        f = lyric_canvas.frame_at(at + s["lyric_offset"])
                        ctrl.finish_base = f
                        f = apply_finish(f, s["finish"])
                        sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                        if ctrl.dirty.wait(0.08):
                            ctrl.dirty.clear()
                        continue
                    # With no cover, clear the previous face instead of leaving
                    # an unrelated lamp or drawing under the Lyrics label.
                    if last_pre is None:
                        empty = Image.new("RGB", (size, size))
                        ctrl.finish_base = empty
                        sink.show(black, pre_wb_img=empty)
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
                    f = countdown.frame_at(left, tm["total"], tm.get("kind", "countdown"),
                                           tm.get("snoozed", False))
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    # the ring drains continuously and the alarm is motion:
                    # a steady thirty frames a second, both ways
                    if ctrl.dirty.wait(1.0 / 30.0):
                        ctrl.dirty.clear()
                    continue

                if mode == "clock":
                    key = (ink, s["clock_24h"])
                    if clock is None or key != clock_key:
                        clock = Clock(size, color=ink,
                                      twenty_four=s["clock_24h"])
                        clock_key = key
                    f = clock.frame_at(0.0)
                    ctrl.finish_base = f
                    f = apply_finish(f, s["finish"])
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    if ctrl.dirty.wait(0.5):
                        ctrl.dirty.clear()
                    continue

                if mode == "video" and ctrl.video is not None:
                    img, wait_s = ctrl.video.frame_at()
                    if img is None:
                        # over, or it never started: back to the face before
                        why = ctrl.video.error
                        ctrl.video_stop(error=why)
                        print("[video] " + (f"failed: {why}" if why else "over; back to "
                                            + ctrl.get()["mode"]))
                        continue
                    if img is not video_shown or sl is not None or waking:
                        ctrl.finish_base = img
                        f = apply_finish(img, s["finish"])
                        # the floor lift is a still sleeve's; a video keeps
                        # its blacks unless the tuning says otherwise
                        sink.show(white_balance(f, eff,
                                                floor=bool(tune.get("video_floor"))).tobytes(),
                                  pre_wb_img=f)
                        video_shown = img
                    if ctrl.dirty.wait(max(0.0, min(wait_s, 0.5))):
                        ctrl.dirty.clear()
                    continue

                if mode == "clip" and ctrl.clip is not None:
                    c = ctrl.clip
                    if clip_id != id(c):
                        clip_id, clip_i = id(c), 0        # a new clip starts at its first frame
                    if c.get("once") and clip_i >= len(c["frames"]):
                        # played through: back to the face it interrupted
                        ctrl.clip = None
                        ctrl.apply({"mode": c.get("ret") or "art"})
                        continue
                    tick = time.monotonic()
                    if tick >= clip_next:
                        frame = c["frames"][clip_i % len(c["frames"])]
                        f = Image.frombytes("RGB", (size, size), frame)
                        ctrl.finish_base = f
                        f = apply_finish(f, s["finish"])
                        sink.show(white_balance(f, eff).tobytes(),
                                  pre_wb_img=f)
                        clip_i += 1
                        clip_next = tick + 1.0 / c["fps"]
                    if ctrl.dirty.wait(max(0.0, clip_next
                                           - time.monotonic())):
                        ctrl.dirty.clear()
                    continue

                if mode == "imagine" and ctrl.imaginer is not None:
                    # a picture being drawn, partial by partial, then held
                    tick = time.monotonic()
                    live = ctrl.imaginer.live
                    if live.expired(tick) or live.stage == "idle":
                        ctrl.imaginer.release()
                        continue
                    f = live.frame_at(size, tick)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    # frames flow while it draws; the held picture only needs a nudge
                    wait = max(0.02, 1.0 / min(anim_fps, 30.0)) if live.busy() or tick - live.updated_at < 1.5 else 0.5
                    if ctrl.dirty.wait(wait):
                        ctrl.dirty.clear()
                    continue
                if mode == "game" and ctrl.games is not None:
                    tick = time.monotonic()
                    f = ctrl.games.frame_at(size, tick)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    # a board changes on a move, not every frame: redraw on
                    # the nudge, or at a gentle rate for the games that animate
                    if ctrl.dirty.wait(max(0.02, 1.0 / min(anim_fps, 30.0))):
                        ctrl.dirty.clear()
                    continue
                if mode == "weather" and ctrl.weather is not None:
                    if weather_face is None:
                        weather_face = WeatherFace(size)
                        weather_t0 = time.monotonic()
                    tick = time.monotonic()
                    where = ctrl.weather.where() or (None, None)
                    f = weather_face.frame_at(tick - weather_t0, ctrl.weather.current(),
                                              units=s.get("weather_units", "f"),
                                              lat=where[0], lon=where[1],
                                              stale=ctrl.weather.stale(),
                                              place=s.get("place", ""))
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    # slow weather, slow frames: a third of the animated rate is plenty
                    if ctrl.dirty.wait(max(0.05, 3.0 / anim_fps)):
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
                    # rebuilt when the picture changes (pressing_seq), not
                    # when the phone re-sends the same one
                    if disc_key != (ctrl.pressing_seq, id(last_pre), s["spin_face"]) \
                            and last_pre is not None:
                        animator = build_disc(last_pre)
                        disc_key = (ctrl.pressing_seq, id(last_pre), s["spin_face"])
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
                    ctrl.finish_base = f
                    f = apply_finish(f, s["finish"])
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    pace(tick)
                    continue

                if waking and last_pre is None:
                    # A morning must still produce light before the first
                    # album has ever arrived. This is only the active fade;
                    # normal artwork and the chosen idle policy resume after.
                    f = Image.new("RGB", (size, size), (255, 244, 222))
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    if ctrl.dirty.wait(0.5):
                        ctrl.dirty.clear()
                    continue

                # static sleeve ("art", or "cd" before any art has arrived)
                # The preview the phone asks for is of the face that is up, so
                # it is named here, on every pass. Naming it only when a sleeve
                # loaded left the previews showing whichever face had rendered
                # last, which is to say always one behind.
                if last_pre is not None:
                    ctrl.finish_base = last_pre
                if need_show and last_pre is not None:
                    if (id(last_pre), s["finish"]) != fin_key:
                        fin_img = apply_finish(last_pre, s["finish"])
                        fin_key = (id(last_pre), s["finish"])
                    sink.show(white_balance(fin_img, eff).tobytes(),
                              pre_wb_img=fin_img)
                    need_show = False
                wait_s = poll_end - time.monotonic()
                if sl is not None or waking:   # keep fading while static
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
