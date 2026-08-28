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
from .art.pipeline import apply_finish, dominant_colors, prepare, white_balance
from .art.text_modes import Clock, Ticker
from .control import ControlState, serve as serve_control
from .nowplaying import SourceChain
from .nowplaying.applemusic import AppleMusicSource
from .nowplaying.spotify import SpotifySource
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


def build_sources(cfg: dict):
    order = cfg.get("nowplaying", {}).get("adapters", ["applemusic"])
    sources = []
    for name in order:
        if name == "applemusic":
            sources.append(AppleMusicSource(
                cfg.get("applemusic", {}).get("endpoint", "")))
        elif name == "spotify":
            cid = cfg.get("spotify", {}).get("client_id", "")
            if not cid or cid.startswith("PASTE"):
                print("[main] spotify listed but no client_id — skipping")
                continue
            sp = SpotifySource(cid,
                               int(cfg["spotify"].get("redirect_port", 8888)))
            if sp.ensure_auth(interactive=sys.stdin.isatty()):
                sources.append(sp)
            else:
                print("[main] spotify: no tokens — skipping")
        else:
            print(f"[main] adapter {name!r} not available yet "
                  "(acoustid/lastfm/localplayer land at S3) — skipping")
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
    anim_fps = float(anim.get("fps", 20))
    ctrl = ControlState(seed={
        "mode": "cd" if anim.get("mode") == "cd" else "art",
        "rpm": float(anim.get("rpm", 7.5)),
    })
    serve_control(ctrl, int(cfg.get("control", {}).get("port", 8788)))

    source = SourceChain(build_sources(cfg))
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
    ticker, ticker_key, ticker_t0 = None, None, 0.0
    clock, clock_key = None, None
    clip_i, clip_next = 0, 0.0
    black = bytes(size * size * 3)

    while True:
        # ---- phone asked to re-show something from the journal ----------
        if ctrl.replay is not None:
            entry, ctrl.replay = ctrl.replay, None
            try:
                pre = prepare(
                    fetch_art(entry["art_url"]), size,
                    unsharp_radius=float(pipe.get("unsharp_radius", 1.0)),
                    unsharp_percent=int(pipe.get("unsharp_percent", 60)),
                )
                last_pre = pre
                animator = DiscAnimator(pre, size, rpm=ctrl.get()["rpm"])
                t0 = time.monotonic()
                need_show = True
                ctrl.now_showing = {"title": entry.get("title", "?"),
                                    "artist": entry.get("artist", "?"),
                                    "album": entry.get("album", "")}
                ctrl.art_colors = dominant_colors(pre)
                hold_until = time.monotonic() + 600   # current track waits
                print(f"[main] replay: {entry.get('artist')} — "
                      f"{entry.get('title')}")
            except Exception as exc:
                print(f"[main] replay failed: {exc}")

        # ---- poll now-playing; rebuild art state on track change --------
        now = source.get_current()
        if now and now.track_id != last_track \
                and time.monotonic() >= hold_until:
            if now.art_url:
                try:
                    pre = prepare(
                        fetch_art(now.art_url), size,
                        unsharp_radius=float(pipe.get("unsharp_radius", 1.0)),
                        unsharp_percent=int(pipe.get("unsharp_percent", 60)),
                    )
                    last_pre = pre
                    animator = DiscAnimator(pre, size, rpm=ctrl.get()["rpm"])
                    t0 = time.monotonic()
                    last_track = now.track_id
                    need_show = True
                    ctrl.now_showing = {"title": now.title,
                                        "artist": now.artist,
                                        "album": now.album}
                    ctrl.art_colors = dominant_colors(pre)
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
                fade = 1.0                       # sleep fade scales brightness
                if ctrl.sleep is not None:
                    el_min = (time.time() - ctrl.sleep["t0"]) / 60.0
                    if el_min >= ctrl.sleep["minutes"]:
                        ctrl.sleep = None
                        ctrl.apply({"mode": "off"})
                        s = ctrl.get()
                    else:
                        fade = 1.0 - el_min / ctrl.sleep["minutes"]
                eff = tuple(g * s["brightness"] * fade for g in gains)
                mode = s["mode"]

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
                    if frame_shown is not ctrl.frame_override:
                        f = Image.frombytes("RGB", (size, size),
                                            ctrl.frame_override)
                        sink.show(white_balance(f, eff).tobytes(),
                                  pre_wb_img=f)
                        frame_shown = ctrl.frame_override
                    if ctrl.dirty.wait(poll_end - time.monotonic()):
                        ctrl.dirty.clear()
                        frame_shown = None
                    continue

                if s["match_art"] and ctrl.art_colors is None \
                        and last_pre is not None:
                    ctrl.art_colors = dominant_colors(last_pre)
                ink = (ctrl.art_colors[0]
                       if s["match_art"] and ctrl.art_colors else s["color"])

                if mode == "ticker":
                    key = (s["ticker_text"], ink, s["speed"], s["ticker_loop"])
                    if ticker is None or key != ticker_key:
                        ticker = Ticker(size, s["ticker_text"], color=ink,
                                        speed=s["speed"],
                                        loop=s["ticker_loop"])
                        ticker_key, ticker_t0 = key, time.monotonic()
                    tick = time.monotonic()
                    if ticker.done(tick - ticker_t0):
                        ctrl.apply({"mode": "art"})
                        continue
                    f = ticker.frame_at(tick - ticker_t0)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    if ctrl.dirty.wait(max(0.0, 1.0 / anim_fps
                                           - (time.monotonic() - tick))):
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
                    if ctrl.dirty.wait(max(0.0, 1.0 / anim_fps
                                           - (time.monotonic() - tick))):
                        ctrl.dirty.clear()
                    continue

                if mode == "cd" and animator is not None:
                    if animator.rpm != s["rpm"]:
                        animator.rpm = s["rpm"]  # angle jumps; S4 owns this
                    tick = time.monotonic()
                    f = animator.frame_at(tick - t0)
                    sink.show(white_balance(f, eff).tobytes(), pre_wb_img=f)
                    if ctrl.dirty.wait(max(0.0, 1.0 / anim_fps
                                           - (time.monotonic() - tick))):
                        ctrl.dirty.clear()
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
                if ctrl.sleep is not None:       # keep fading while static
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
