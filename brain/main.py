"""Album-Art Matrix brain: poll now-playing, run the art pipeline on track
change, push the frame to the sink.

Mac (dev):  .venv/bin/python -m brain.main --config config.toml   (sink=preview)
Pi (live):  same, with [sink] type = "pi", pi/run_renderer.sh running, and
            [applemusic] endpoint pointed at the Mac's reporter.
"""
import argparse
import sys
import time

if sys.version_info < (3, 11):
    sys.exit("python >= 3.11 required (tomllib) — found "
             + ".".join(map(str, sys.version_info[:3])))
import tomllib

from .art.fetch import fetch_art
from .art.pipeline import process
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

    source = SourceChain(build_sources(cfg))
    sink = make_sink(cfg, args.sink)

    print(f"[main] adapters: {[s.name for s in source.sources]}, "
          f"panel {size}x{size}, poll {poll_s:.0f}s, "
          f"gains R{gains[0]:.2f}/G{gains[1]:.2f}/B{gains[2]:.2f}")

    last_track = None
    while True:
        now = source.get_current()
        if now and now.track_id != last_track:
            if now.art_url:
                try:
                    img = fetch_art(now.art_url)
                    pre, frame = process(
                        img, size, gains,
                        unsharp_radius=float(pipe.get("unsharp_radius", 1.0)),
                        unsharp_percent=int(pipe.get("unsharp_percent", 60)),
                    )
                    sink.show(frame, pre_wb_img=pre)
                    last_track = now.track_id
                    print(f"[main] {now.artist} — {now.title}  ({now.album})")
                except Exception as exc:
                    print(f"[main] art pipeline failed: {exc}")
            else:
                print(f"[main] no art found for {now.artist} — {now.title}")
                last_track = now.track_id
        if args.once:
            break
        try:
            time.sleep(poll_s)
        except KeyboardInterrupt:
            print("\n[main] bye")
            break


if __name__ == "__main__":
    main()
