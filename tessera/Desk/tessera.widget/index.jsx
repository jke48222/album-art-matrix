import { React } from "uebersicht";

// Tessera on the desk.
//
// An Übersicht widget that keeps the wall in a corner of the Mac's desktop:
// the frame the wall is showing right now, drawn LED by LED the way the
// phone app draws it, the song under it, the faces as chips, and the
// brightness on the scroll wheel. It talks to the brain's HTTP API directly
// from the desktop's web view, so there is no shell command and no helper.
//
// Two polls: the frame once a second, the state every other second. When the
// wall stops answering, the widget keeps the last frame and says so, the way
// the app does, rather than blanking the desktop.

export const command = false;          // the widget polls the wall itself
export const refreshFrequency = false;

// The wall, by the names the app uses. The first one that answers wins, so
// the same file works against the Pi and against a brain running on this Mac.
const HOSTS = ["album-matrix.local:8788", "localhost:8788"];
const ASK = 64;               // the side the wall is asked for (a 192 wall box-averages down)
const PX = 4;                 // canvas pixels per LED
const FONTS = "tessera.widget/fonts";
const LAYOUT = [740, 40];     // where the card lands until it is dragged
const W = 280;                // card width; the panel is 256 inside 12 of padding
const TAU = Math.PI * 2;

// Theme.swift, in CSS. A dark room, one lit tile.
const Ink = {
  ground: "#0B0A09", plaster: "#141210", sunk: "#0E0D0B",
  ink: "#EAE4D8", dim: "#96907F", faint: "#837C6C",
  hairline: "rgba(234,228,216,0.13)",
  tile: "#E8B04B",     // a lit tessera; pending states
  signal: "#E0491F",   // warnings only
  moss: "#7FA87A",     // confirmed on the wall
};

// The faces that are plain modes. Design, Video and Games open sheets in the
// app that the desk has no equivalent for, so they stay on the phone.
const FACES = [
  ["art", "Art"], ["cd", "Spin"], ["lyrics", "Lyrics"], ["nine", "Nine"],
  ["ambient", "Lamp"], ["clock", "Clock"], ["off", "Off"],
];
const faceName = (mode) => {
  const f = FACES.find((x) => x[0] === mode);
  return f ? f[1] : (mode ? mode[0].toUpperCase() + mode.slice(1) : "");
};

// ---- the store ----------------------------------------------------------
// One object on window, so a re-render or a module reload after an edit
// reuses the same poll loop instead of stacking a second one.
const store = () => {
  if (!window.__ts) {
    window.__ts = {
      host: null, hostAt: 0,   // which wall answered, and when we last looked
      state: null,             // GET /state, as the brain sent it
      px: null, side: ASK,     // the last frame, RGB888 bytes
      seen: 0, misses: 0,      // last good tick, failed ticks in a row
      phase: "looking",        // looking | live | away
      bright: null,            // brightness as the wheel left it
      wheelAt: 0,              // when the wheel last moved (the wall's value waits)
      n: 0, busy: false, bump: null,
    };
  }
  return window.__ts;
};

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

// fetch with a deadline. A wall that is off does not refuse, it just never
// answers, so every request carries its own timeout.
const timed = (url, ms, binary) => {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), ms);
  return fetch(url, { signal: c.signal, cache: "no-store" })
    .then((r) => {
      if (r.status === 404 && binary) return null;   // "nothing shown yet"
      if (!r.ok) throw new Error("http " + r.status);
      return binary ? r.arrayBuffer() : r.json();
    })
    .finally(() => clearTimeout(t));
};

const findHost = () =>
  Promise.all(HOSTS.map((h) => timed(`http://${h}/health`, 1500).then(() => h, () => null)))
    .then((r) => r.find(Boolean) || null);

const post = (path, body) => {
  const s = store();
  if (!s.host) return Promise.resolve();
  return fetch(`http://${s.host}${path}`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
    .then((r) => r.json())
    .then((st) => { if (st && st.mode) s.state = st; if (s.bump) s.bump(); })
    .catch(() => {});
};

// One tick: find a wall if we have none, otherwise pull the frame (and, every
// other tick, the state). Three misses in a row and the wall is "away": the
// last frame stays up and the search starts again.
const tick = () => {
  const s = store();
  if (s.busy) return;
  s.busy = true;
  const done = () => { s.busy = false; if (s.bump) s.bump(); };

  if (!s.host) {
    if (Date.now() - s.hostAt < 4000) { s.busy = false; return; }
    s.hostAt = Date.now();
    findHost().then((h) => { if (h) { s.host = h; s.misses = 0; } }).then(done, done);
    return;
  }

  const base = `http://${s.host}`;
  s.n += 1;
  const jobs = [
    timed(`${base}/frame.raw?side=${ASK}`, 1500, true).then((buf) => {
      if (!buf) return;
      const px = new Uint8Array(buf);
      const side = Math.round(Math.sqrt(px.length / 3));
      if (side * side * 3 === px.length) { s.px = px; s.side = side; paint(); }
    }),
  ];
  if (s.n % 2 === 1 || !s.state) {
    jobs.push(timed(`${base}/state`, 1500).then((st) => {
      s.state = st;
      // the wheel's value wins for a moment, then the wall's own wins
      if (Date.now() - s.wheelAt > 1500) s.bright = st.brightness;
    }));
  }
  Promise.all(jobs).then(
    () => { s.seen = Date.now(); s.misses = 0; s.phase = "live"; },
    () => {
      s.misses += 1;
      if (s.misses >= 3) { s.phase = s.seen ? "away" : "looking"; s.host = null; }
    },
  ).then(done, done);
};

const ensureLoop = () => {
  if (window.__tsTimer) clearInterval(window.__tsTimer);
  window.__tsTimer = setInterval(tick, 1000);
  tick();
};

// ---- the panel ----------------------------------------------------------
// The same emitters as PanelCanvas in FrameView.swift: a core dot of 0.40 of
// a cell, a halo that grows with the LED's luminance and shrinks with the
// duty, unlit LEDs as near-black dots, dimming that goes warm rather than
// grey. Halos first, cores over the top, so neighbours merge into a picture.
const paint = () => {
  const s = store();
  const cv = document.getElementById("ts-panel");
  if (!cv || !s.px) return;
  const side = s.side, size = side * PX;
  if (cv.width !== size) { cv.width = size; cv.height = size; }
  const ctx = cv.getContext("2d");
  const cell = PX, r = cell * 0.40;
  const d = clamp(s.bright == null ? 1 : s.bright, 0.05, 1);
  const warm = 0.18 * (1 - d), gK = 1 - warm * 0.34, bK = 1 - warm;
  const px = s.px, n = side * side;

  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, size, size);

  ctx.fillStyle = "rgb(14,14,14)";   // Color(white: 0.055)
  ctx.beginPath();
  for (let i = 0; i < n; i++) {
    const o = i * 3;
    const lum = 0.2126 * px[o] + 0.7152 * px[o + 1] + 0.0722 * px[o + 2];
    if (lum >= 8) continue;
    const cx = (i % side) * cell + cell / 2, cy = Math.floor(i / side) * cell + cell / 2;
    ctx.moveTo(cx + r, cy);
    ctx.arc(cx, cy, r, 0, TAU);
  }
  ctx.fill();

  for (let pass = 0; pass < 2; pass++) {
    for (let i = 0; i < n; i++) {
      const o = i * 3;
      const R = px[o], G = px[o + 1], B = px[o + 2];
      const lum = 0.2126 * R + 0.7152 * G + 0.0722 * B;
      if (lum < 8) continue;
      const cx = (i % side) * cell + cell / 2, cy = Math.floor(i / side) * cell + cell / 2;
      const cr = Math.round(R * d), cg = Math.round(G * d * gK), cb = Math.round(B * d * bK);
      const k = lum / 255;
      if (pass === 0) {
        const hr = r + cell * 0.72 * k * d;
        ctx.fillStyle = `rgba(${cr},${cg},${cb},${(0.28 * k * Math.pow(d, 1.4)).toFixed(3)})`;
        ctx.beginPath(); ctx.arc(cx, cy, hr, 0, TAU); ctx.fill();
      } else {
        ctx.fillStyle = `rgb(${cr},${cg},${cb})`;
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, TAU); ctx.fill();
      }
    }
  }
};

// ---- drag and resize ----------------------------------------------------
// The same grips as the rest of the desk: Übersicht puts each widget in its
// own absolutely positioned .widget node, so that is what moves. Position
// and scale persist in localStorage and survive reloads.
const wrapperOf = (node) => node && node.closest(".widget");
const applySaved = (w) => {
  try {
    const pos = JSON.parse(localStorage.getItem("ts:pos") || "null");
    if (pos && typeof pos.x === "number") { w.style.left = pos.x + "px"; w.style.top = pos.y + "px"; }
  } catch (e) { /* storage unavailable */ }
  try {
    const sc = parseFloat(localStorage.getItem("ts:scale"));
    if (sc > 0) w.style.transform = `scale(${sc})`;
  } catch (e) { /* storage unavailable */ }
};

const initDrag = (node) => {
  const w = wrapperOf(node);
  if (!node || !w) return;
  applySaved(w);
  if (node.__wired) return;
  node.__wired = true;
  node.addEventListener("click", (e) => e.stopPropagation());
  node.addEventListener("mousedown", (e) => {
    e.preventDefault(); e.stopPropagation();
    const sx = e.clientX, sy = e.clientY, cs = getComputedStyle(w);
    const ox = parseFloat(w.style.left || cs.left) || 0, oy = parseFloat(w.style.top || cs.top) || 0;
    const move = (ev) => { w.style.left = ox + (ev.clientX - sx) + "px"; w.style.top = oy + (ev.clientY - sy) + "px"; };
    const up = () => {
      document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up);
      try { localStorage.setItem("ts:pos", JSON.stringify({ x: parseFloat(w.style.left) || 0, y: parseFloat(w.style.top) || 0 })); } catch (e) { /* ignore */ }
    };
    document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
  });
  node.addEventListener("dblclick", (e) => {
    e.preventDefault(); e.stopPropagation();
    try { localStorage.removeItem("ts:pos"); } catch (e) { /* ignore */ }
    w.style.left = ""; w.style.top = "";
  });
};

const initResize = (node) => {
  const w = wrapperOf(node);
  if (!node || !w) return;
  applySaved(w);
  if (node.__wired) return;
  node.__wired = true;
  node.addEventListener("click", (e) => e.stopPropagation());
  node.addEventListener("mousedown", (e) => {
    e.preventDefault(); e.stopPropagation();
    const sx = e.clientX, sy = e.clientY, cs = getComputedStyle(w);
    const bw = parseFloat(cs.width) || 1, bh = parseFloat(cs.height) || 1;
    const m = /scale\(([^)]+)\)/.exec(w.style.transform || "");
    const o = m ? parseFloat(m[1]) || 1 : 1;
    const move = (ev) => {
      const delta = (ev.clientX - sx + (ev.clientY - sy)) / (bw + bh);
      w.style.transform = `scale(${clamp(o + delta, 0.4, 3)})`;
    };
    const up = () => {
      document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up);
      const m2 = /scale\(([^)]+)\)/.exec(w.style.transform || "");
      try { localStorage.setItem("ts:scale", String(m2 ? m2[1] : 1)); } catch (e) { /* ignore */ }
    };
    document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
  });
  node.addEventListener("dblclick", (e) => {
    e.preventDefault(); e.stopPropagation();
    try { localStorage.removeItem("ts:scale"); } catch (e) { /* ignore */ }
    w.style.transform = "";
  });
};

// ---- the card -----------------------------------------------------------
const mmss = (ms) => {
  if (!ms || ms < 0) return "0:00";
  const t = Math.floor(ms / 1000);
  return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`;
};

class Desk extends React.Component {
  constructor(props) {
    super(props);
    this.state = { hint: null };
    this.onWheel = this.onWheel.bind(this);
  }

  componentDidMount() {
    store().bump = () => this.forceUpdate();
    ensureLoop();
    paint();
  }

  componentWillUnmount() {
    store().bump = null;
  }

  componentDidUpdate() {
    paint();   // cheap, and it covers the canvas being remounted on a reload
  }

  setMode(mode) {
    const s = store();
    if (!s.state || s.state.mode === mode) return;
    s.state = { ...s.state, mode };   // the chip lights before the wall answers
    this.forceUpdate();
    post("/state", { mode });
  }

  // Swipe up over the panel to brighten it, down to dim it: the same motion
  // as the drag on the phone's panel. deltaY is positive for a swipe up
  // under macOS's natural scrolling. 800 pixels is the whole range, one long
  // swipe. The wall is told once the wheel stops for a moment, not per notch.
  onWheel(e) {
    const s = store();
    if (!s.state) return;
    const from = s.bright == null ? (s.state.brightness || 1) : s.bright;
    s.bright = clamp(from + e.deltaY / 800, 0.05, 1);
    s.wheelAt = Date.now();
    this.setState({ hint: `${Math.round(s.bright * 100)}%` });
    paint();
    clearTimeout(this.sendT);
    this.sendT = setTimeout(() => post("/state", { brightness: Math.round(s.bright * 100) / 100 }), 250);
    clearTimeout(this.hintT);
    this.hintT = setTimeout(() => this.setState({ hint: null }), 1200);
  }

  render() {
    const s = store();
    const st = s.state || {};
    const now = st.now_showing || {};
    const pr = st.progress || {};
    const accent = (st.art_colors && st.art_colors[0]) || Ink.tile;
    const live = s.phase === "live";
    const bright = s.bright == null ? st.brightness : s.bright;
    const at = pr.of
      ? clamp((pr.at || 0) + (pr.playing && pr.stamped ? Date.now() - pr.stamped * 1000 : 0), 0, pr.of)
      : 0;
    const link = live ? s.host.replace(/:\d+$/, "") : s.phase === "away" ? "away" : "looking";

    return (
      <div className="card">
        <div className="grip" title="Drag to move. Double-click to put it back." ref={initDrag}>☰</div>

        <div className="panel" onWheel={this.onWheel} title="Scroll to dim or brighten the wall">
          <canvas id="ts-panel" width={ASK * PX} height={ASK * PX} />
          {!s.px && <div className="dark">{s.phase === "looking" ? "Looking for the wall" : "Nothing here yet"}</div>}
          {this.state.hint && <div className="hint">{this.state.hint}</div>}
        </div>

        <div className="words">
          <div className="title">{now.title || (st.mode ? faceName(st.mode) : "")}</div>
          <div className="who">
            {now.artist || ""}
            {now.album ? <span className="album">{now.album}</span> : null}
          </div>
          <div className="bar"><i style={{ width: pr.of ? `${(100 * at) / pr.of}%` : 0, background: accent }} /></div>
          <div className="meta">
            <span>{pr.of ? `${mmss(at)} / ${mmss(pr.of)}` : ""}</span>
            {st.owned ? <span className="owned">on your shelf</span> : null}
          </div>
        </div>

        <div className="faces">
          {FACES.map(([mode, label]) => {
            const on = st.mode === mode;
            return (
              <div key={mode} className={"chip" + (on ? " on" : "")}
                   style={on ? { background: accent, borderColor: accent, color: Ink.ground } : null}
                   onClick={() => this.setMode(mode)}>{label}</div>
            );
          })}
        </div>

        <div className="foot">
          <span className={"link " + s.phase}><b /> {link}</span>
          <span className="right">
            {!live && s.seen ? "Showing the last thing your wall had."
              : st.mode ? `${faceName(st.mode)}  ${Math.round((bright || 0) * 100)}%` : ""}
          </span>
        </div>

        <div className="corner" title="Drag to resize. Double-click to reset." ref={initResize}>⤡</div>
      </div>
    );
  }
}

export const render = () => <Desk />;

export const className = `
  position: absolute; left: ${LAYOUT[0]}px; top: ${LAYOUT[1]}px;
  width: ${W}px; transform-origin: top left; will-change: transform;
  -webkit-user-select: none; user-select: none;

  @font-face { font-family: "Technor"; font-weight: 700;
               src: url("${FONTS}/Technor-Bold.otf") format("opentype"); }
  @font-face { font-family: "Switzer"; font-weight: 400;
               src: url("${FONTS}/Switzer-Regular.otf") format("opentype"); }
  @font-face { font-family: "Switzer"; font-weight: 500;
               src: url("${FONTS}/Switzer-Medium.otf") format("opentype"); }
  @font-face { font-family: "Martian Mono"; font-weight: 400;
               src: url("${FONTS}/MartianMono-Regular.ttf") format("truetype"); }

  .card { position: relative; padding: 12px; border-radius: 20px; box-sizing: border-box;
          background: ${Ink.ground}; color: ${Ink.ink};
          box-shadow: 0 0 0 1px ${Ink.hairline}, 0 12px 40px rgba(0,0,0,0.45);
          font-family: "Switzer", -apple-system, sans-serif; font-weight: 400; }

  .panel { position: relative; width: ${ASK * PX}px; height: ${ASK * PX}px;
           border-radius: 10px; overflow: hidden; background: #000; cursor: ns-resize; }
  .panel canvas { display: block; width: 100%; height: 100%; }
  .panel .dark { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
                 font-family: "Martian Mono", ui-monospace, monospace; font-size: 9px; letter-spacing: 1px;
                 text-transform: uppercase; color: ${Ink.faint}; }
  .panel .hint { position: absolute; right: 8px; bottom: 8px; padding: 3px 7px; border-radius: 6px;
                 background: rgba(11,10,9,0.82); font-family: "Martian Mono", ui-monospace, monospace;
                 font-size: 10px; color: ${Ink.ink}; }

  .words { padding: 12px 2px 0; }
  .title { font-family: "Technor", "Switzer", sans-serif; font-weight: 700; font-size: 17px; line-height: 1.15;
           letter-spacing: 0.1px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-height: 20px; }
  .who   { margin-top: 3px; font-size: 12px; font-weight: 500; color: ${Ink.dim};
           white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-height: 15px; }
  .who .album { margin-left: 8px; font-weight: 400; color: ${Ink.faint}; }
  .bar   { margin-top: 9px; height: 2px; border-radius: 1px; background: ${Ink.hairline}; overflow: hidden; }
  .bar i { display: block; height: 100%; transition: width .6s linear; }
  .meta  { display: flex; justify-content: space-between; margin-top: 5px; min-height: 12px;
           font-family: "Martian Mono", ui-monospace, monospace; font-size: 9px; letter-spacing: 0.4px;
           color: ${Ink.faint}; }
  .meta .owned { color: ${Ink.moss}; }

  .faces { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 12px; }
  .chip  { padding: 4px 9px; border-radius: 999px; border: 1px solid ${Ink.hairline};
           background: ${Ink.plaster}; color: ${Ink.dim}; font-size: 10.5px; font-weight: 500;
           letter-spacing: 0.2px; cursor: pointer; transition: color .15s ease, background .15s ease; }
  .chip:hover { color: ${Ink.ink}; }
  .chip.on { font-weight: 500; }

  .foot  { display: flex; justify-content: space-between; align-items: baseline; gap: 8px;
           margin-top: 12px; padding: 0 2px; font-family: "Martian Mono", ui-monospace, monospace;
           font-size: 8.5px; letter-spacing: 0.6px; text-transform: uppercase; color: ${Ink.faint}; }
  .foot .right { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-transform: none;
                 letter-spacing: 0.3px; }
  .link b { display: inline-block; width: 6px; height: 6px; border-radius: 50%; margin-right: 2px;
            background: ${Ink.faint}; vertical-align: 0; }
  .link.live b { background: ${Ink.moss}; }
  .link.looking b { background: ${Ink.tile}; animation: ts-breathe 1.6s ease-in-out infinite; }
  @keyframes ts-breathe { 0%,100% { opacity: 0.35; } 50% { opacity: 1; } }

  .grip, .corner { position: absolute; z-index: 5; width: 18px; height: 18px; border-radius: 6px;
                   display: flex; align-items: center; justify-content: center; font-size: 11px;
                   line-height: 1; opacity: 0; transition: opacity .15s ease; color: ${Ink.dim};
                   background: rgba(234,228,216,0.08); }
  .card:hover .grip, .card:hover .corner { opacity: 0.55; }
  .grip:hover, .corner:hover { opacity: 1 !important; }
  .grip { top: 6px; left: 6px; cursor: grab; }
  .grip:active { cursor: grabbing; }
  .corner { bottom: 5px; right: 5px; cursor: nwse-resize; }
`;
