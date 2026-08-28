/** Test pattern generators. Each returns RGBA pixel data at a chosen size. */

export type PatternId =
  | "synthetic"
  | "white"
  | "red"
  | "green"
  | "blue"
  | "ramp"
  | "checker";

export interface RgbaImage {
  data: Uint8ClampedArray;
  width: number;
  height: number;
}

export const PATTERNS: { id: PatternId; label: string; purpose: string }[] = [
  {
    id: "synthetic",
    label: "Synthetic cover",
    purpose: "Gradient, vinyl disc and fine detail — exposes banding, aliasing and downscale mush.",
  },
  { id: "white", label: "Full white", purpose: "Every pixel 255. Measure white balance against a real panel." },
  { id: "red", label: "Full red", purpose: "Per-channel output, red emitters only." },
  { id: "green", label: "Full green", purpose: "Per-channel output, green emitters only." },
  { id: "blue", label: "Full blue", purpose: "Per-channel output, blue emitters only." },
  { id: "ramp", label: "Greyscale ramp", purpose: "Stepped ramp for spotting banding and gamma errors." },
  { id: "checker", label: "Pixel checkerboard", purpose: "1-pixel checker for alignment." },
];

function blank(size: number): RgbaImage {
  const data = new Uint8ClampedArray(size * size * 4);
  for (let i = 3; i < data.length; i += 4) data[i] = 255;
  return { data, width: size, height: size };
}

function set(img: RgbaImage, x: number, y: number, r: number, g: number, b: number) {
  const o = (y * img.width + x) * 4;
  img.data[o] = r;
  img.data[o + 1] = g;
  img.data[o + 2] = b;
  img.data[o + 3] = 255;
}

export function makePattern(id: PatternId, size = 1024): RgbaImage {
  const img = blank(size);

  switch (id) {
    case "white":
    case "red":
    case "green":
    case "blue": {
      const c =
        id === "white" ? [255, 255, 255] : id === "red" ? [255, 0, 0] : id === "green" ? [0, 255, 0] : [0, 0, 255];
      for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) set(img, x, y, c[0], c[1], c[2]);
      return img;
    }
    case "ramp": {
      const steps = 16;
      for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
          const step = Math.floor((x / size) * steps);
          const v = Math.round((step / (steps - 1)) * 255);
          set(img, x, y, v, v, v);
        }
      }
      return img;
    }
    case "checker": {
      // 1 LED pixel per square once downscaled: block size = size / 64.
      const block = Math.max(1, Math.round(size / 64));
      for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
          const on = (Math.floor(x / block) + Math.floor(y / block)) % 2 === 0;
          const v = on ? 255 : 0;
          set(img, x, y, v, v, v);
        }
      }
      return img;
    }
    case "synthetic":
    default: {
      const cx = size / 2;
      const cy = size / 2;
      for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
          // smooth diagonal colour gradient
          const u = x / (size - 1);
          const v = y / (size - 1);
          let r = Math.round(255 * Math.min(1, u * 0.9 + 0.1));
          let g = Math.round(255 * Math.min(1, (1 - v) * 0.75 + 0.15));
          let b = Math.round(255 * Math.min(1, (u * 0.4 + v * 0.6)));

          // vinyl-style disc with centre hole
          const dx = x - cx;
          const dy = y - cy;
          const d = Math.sqrt(dx * dx + dy * dy);
          const discR = size * 0.34;
          if (d < discR) {
            const groove = 0.5 + 0.5 * Math.sin(d / (size / 220));
            const base = 14 + groove * 26;
            r = base;
            g = base;
            b = base + 4;
            if (d < size * 0.11) {
              // label
              r = 200;
              g = 70;
              b = 50;
            }
            if (d < size * 0.012) {
              // centre hole
              r = 0;
              g = 0;
              b = 0;
            }
          }

          // fine high-frequency detail block, bottom right
          if (x > size * 0.68 && y > size * 0.68) {
            const f = (x + y) % 4 < 2 ? 255 : 20;
            r = f;
            g = f;
            b = f;
          }
          set(img, x, y, r, g, b);
        }
      }
      return img;
    }
  }
}

/** Demo covers, drawn procedurally so nothing needs to be fetched. Labelled as demo content. */
export const DEMO_COVERS = [
  { id: "demo:aurora", title: "Aurora Drift", artist: "Nightpanel", album: "Aurora Drift", hue: 190 },
  { id: "demo:emberfall", title: "Emberfall", artist: "Slow Circuit", album: "Emberfall EP", hue: 22 },
  { id: "demo:violetline", title: "Violet Line", artist: "HUB75", album: "Scanlines", hue: 288 },
  { id: "demo:tealroom", title: "Teal Room", artist: "P2.5", album: "Pitch", hue: 160 },
];

export function makeDemoCover(hue: number, size = 1024): RgbaImage {
  const img = blank(size);
  const cx = size / 2;
  const cy = size / 2;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const u = x / size;
      const v = y / size;
      const h = (hue + u * 60 - v * 30 + 360) % 360;
      const s = 0.55 + 0.35 * v;
      const l = 0.18 + 0.5 * (1 - v) * (0.4 + 0.6 * u);
      const [r, g, b] = hslToRgb(h / 360, s, l);
      set(img, x, y, r, g, b);
    }
  }
  // a bold geometric mark so downscale legibility is judgeable
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = Math.abs(x - cx);
      const dy = Math.abs(y - cy);
      const ring = Math.sqrt(dx * dx + dy * dy);
      if (ring > size * 0.26 && ring < size * 0.30) set(img, x, y, 250, 248, 240);
      if (dy < size * 0.018 && dx < size * 0.34) set(img, x, y, 12, 12, 14);
    }
  }
  return img;
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  const f = (n: number) => {
    const k = (n + h * 12) % 12;
    const a = s * Math.min(l, 1 - l);
    return Math.round(255 * (l - a * Math.max(-1, Math.min(k - 3, Math.min(9 - k, 1)))));
  };
  return [f(0), f(8), f(4)];
}
