/**
 * The room is lit by the wall.
 *
 * From the frame the wall is actually showing, derive:
 *   --amb-1 / --amb-2  two spill colours (bright quarter, and the rest)
 *   --art              the dominant colour, lifted to a usable UI accent
 *   --wall-lit         0..1 - how much light the wall emits at all, so a
 *                      black wall leaves the room genuinely dark
 *
 * Pure functions + one DOM applier. No React.
 */

const FALLBACK: [string, string] = ["rgb(64 52 38)", "rgb(38 32 46)"];

export interface RoomLight {
  spill: [string, string];
  art: string;
  lit: number; // 0..1
}

export function roomLightFromFrame(buffer: Uint8Array, size: number): RoomLight {
  const px = size * size;
  if (!px) return { spill: FALLBACK, art: "rgb(180 150 110)", lit: 0 };

  const lum = new Float32Array(px);
  let lumSum = 0;
  for (let i = 0; i < px; i++) {
    const o = i * 3;
    const l = 0.2126 * buffer[o] + 0.7152 * buffer[o + 1] + 0.0722 * buffer[o + 2];
    lum[i] = l;
    lumSum += l;
  }
  const mean = lumSum / px / 255;
  // Perceptual-ish gate: a dim frame still lights the room a little.
  const lit = Math.min(1, Math.pow(mean * 3.2, 0.8));

  const sorted = Float32Array.from(lum).sort();
  const cut = sorted[Math.floor(px * 0.75)];

  let hr = 0, hg = 0, hb = 0, hn = 0;
  let lr = 0, lg = 0, lb = 0, ln = 0;
  for (let i = 0; i < px; i++) {
    const o = i * 3;
    if (lum[i] >= cut) {
      hr += buffer[o]; hg += buffer[o + 1]; hb += buffer[o + 2]; hn++;
    } else {
      lr += buffer[o]; lg += buffer[o + 1]; lb += buffer[o + 2]; ln++;
    }
  }

  const spill: [string, string] = hn
    ? [
        boost(hr / hn, hg / hn, hb / hn, 1),
        ln ? boost(lr / ln, lg / ln, lb / ln, 1.4) : FALLBACK[1],
      ]
    : FALLBACK;

  return { spill, art: dominant(buffer, px, lum), lit };
}

/**
 * Dominant colour by coarse histogram: bucket every pixel above a luminance
 * floor into a 4-bit-per-channel cube, take the most populated bucket that is
 * actually chromatic, average its members, then normalise for UI use.
 */
function dominant(buffer: Uint8Array, px: number, lum: Float32Array): string {
  const counts = new Map<number, { n: number; r: number; g: number; b: number; sat: number }>();
  for (let i = 0; i < px; i++) {
    if (lum[i] < 24) continue; // near-black never drives the accent
    const o = i * 3;
    const r = buffer[o], g = buffer[o + 1], b = buffer[o + 2];
    const key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
    const sat = mx ? (mx - mn) / mx : 0;
    const e = counts.get(key);
    if (e) {
      e.n++; e.r += r; e.g += g; e.b += b; e.sat += sat;
    } else {
      counts.set(key, { n: 1, r, g, b, sat });
    }
  }
  let best: { score: number; r: number; g: number; b: number } | null = null;
  for (const e of counts.values()) {
    // Weight population by average saturation so a grey majority does not
    // out-vote the sleeve's actual colour.
    const score = e.n * (0.25 + (e.sat / e.n) * 0.75);
    if (!best || score > best.score) {
      best = { score, r: e.r / e.n, g: e.g / e.n, b: e.b / e.n };
    }
  }
  if (!best) return "rgb(180 150 110)";
  return boost(best.r, best.g, best.b, 1.05);
}

/** Push a channel triple towards a usable light: keep hue, normalise level. */
function boost(r: number, g: number, b: number, gain: number): string {
  const max = Math.max(r, g, b, 1);
  const k = (255 / max) * 0.82 * gain;
  const c = (v: number) => Math.round(Math.min(255, v * k));
  return `rgb(${c(r)} ${c(g)} ${c(b)})`;
}

export function applyRoomLight(light: RoomLight | null) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  if (!light) {
    root.style.setProperty("--wall-lit", "0");
    return;
  }
  root.style.setProperty("--amb-1", light.spill[0]);
  root.style.setProperty("--amb-2", light.spill[1]);
  root.style.setProperty("--art", light.art);
  root.style.setProperty("--wall-lit", light.lit.toFixed(3));
}

/* Back-compat aliases for existing imports. */
export function ambientFromFrame(buffer: Uint8Array, size: number): [string, string] {
  return roomLightFromFrame(buffer, size).spill;
}
export function applyAmbient(colors: [string, string] | null) {
  if (typeof document === "undefined") return;
  const root = document.documentElement;
  const [a, b] = colors ?? FALLBACK;
  root.style.setProperty("--amb-1", a);
  root.style.setProperty("--amb-2", b);
}
