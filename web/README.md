# Album Art Matrix — web

The software half of the wall, in a browser: the control plane, the exact
image pipeline, a simulator of the physical panels, and the phone remote.
Started as a Lovable build from a long spec, then combined with the hardware
repo and redesigned.

## Run it

```
cd web
npm install
npm run dev
```

Opens on http://localhost:8080. Fully usable with nothing configured: the
demo source is the floor of the chain, and it is labelled as demo content.

## Talking to the real stack

- **Apple Music (primary).** Run `scripts/mac_reporter.py` on the Mac (the
  launchd plist in `scripts/` keeps it up). The web app polls
  `http://localhost:8787/nowplaying` — same endpoint the Pi polls, now with
  CORS so a browser may read it. Point it at `http://<mac>.local:8787/...`
  from a phone.
- **Push to wall.** Setup → Push, format "Pi brain (json)", endpoint
  `http://album-matrix.local:8788/frame`. Sends the processed 64×64 RGB888
  buffer base64-wrapped, exactly what `brain/control.py` accepts, and the
  real wall shows it.

## What is what

```
src/lib/pipeline.ts      The pipeline: Lanczos-3 → unsharp (Pillow semantics,
                         threshold 2) → decode 2.2 → WB gains in linear light
                         → re-encode. Same math as brain/art/pipeline.py.
src/lib/pipeline.worker  The same, off the main thread.
src/lib/sources/         One file per now-playing adapter, one shared contract.
src/lib/render.ts        Nearest-neighbour grid, round-emitter wall, raw view.
src/lib/ambient.ts       The room: spill colours, art accent, and how lit the
                         wall is, all sampled from the actual framebuffer.
src/lib/power.ts         The wiring circuit model (modelled, never measured).
src/routes/              Wall, Sources, History, Balance, Power, Setup.
```

## Design

Dark gallery: the wall is the only light source and the room is lit by it
(CSS variables sampled from the frame). Chrome is museum placards — warm ink
on near-black, hairline rules, Archivo wide for names, IBM Plex Mono for
machine values, signal red reserved for primary actions and real warnings.
Same faces as the iOS companion, so the two clients read as one product.
