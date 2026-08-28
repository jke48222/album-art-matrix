/**
 * Album Art Matrix image pipeline.
 *
 * Pure, standalone, no React / DOM / network. Input is raw RGBA pixel data,
 * output is an N*N*3 RGB888 buffer, row-major, no padding.
 *
 * Order is fixed by spec:
 *   1. Lanczos-3 downscale (separable, horizontal then vertical)
 *   2. Unsharp mask (Pillow semantics, threshold fixed at 2)
 *   3. Decode to linear light with the plain 2.2 power curve
 *   4. White balance gains applied in linear light, then clip to [0,1]
 *   5. Re-encode ^(1/2.2), round with floor(x + 0.5)
 */

import type { PipelineParams, PipelineResult } from "./types";

/* ---------- gamma lookup tables ---------- */

/** 256-entry decode LUT: 8-bit code -> linear light [0,1]. */
export const DECODE_LUT = (() => {
  const t = new Float32Array(256);
  for (let i = 0; i < 256; i++) t[i] = Math.pow(i / 255, 2.2);
  return t;
})();

/** 4096-entry encode LUT: linear light [0,1] -> 8-bit code. */
const ENCODE_STEPS = 4096;
export const ENCODE_LUT = (() => {
  const t = new Uint8Array(ENCODE_STEPS + 1);
  for (let i = 0; i <= ENCODE_STEPS; i++) {
    const v = Math.pow(i / ENCODE_STEPS, 1 / 2.2) * 255;
    t[i] = Math.max(0, Math.min(255, Math.floor(v + 0.5)));
  }
  return t;
})();

function encodeLinear(x: number): number {
  if (x <= 0) return 0;
  if (x >= 1) return 255;
  return ENCODE_LUT[(x * ENCODE_STEPS + 0.5) | 0];
}

/* ---------- step 1: Lanczos-3 ---------- */

const A = 3;

function sinc(x: number): number {
  if (x === 0) return 1;
  const px = Math.PI * x;
  return Math.sin(px) / px;
}

export function lanczos(x: number): number {
  const ax = Math.abs(x);
  if (ax >= A) return 0;
  return sinc(x) * sinc(x / A);
}

interface Contrib {
  starts: Int32Array;
  counts: Int32Array;
  weights: Float32Array;
  maxCount: number;
}

/** Precompute filter contributions for a 1-D resample from srcLen to dstLen. */
function buildContributions(srcLen: number, dstLen: number): Contrib {
  const scale = dstLen / srcLen;
  const filterScale = scale < 1 ? 1 / scale : 1;
  const support = A * filterScale;
  const maxCount = Math.ceil(support * 2) + 2;

  const starts = new Int32Array(dstLen);
  const counts = new Int32Array(dstLen);
  const weights = new Float32Array(dstLen * maxCount);

  for (let i = 0; i < dstLen; i++) {
    const center = (i + 0.5) / scale;
    let left = Math.floor(center - support);
    let right = Math.ceil(center + support);
    if (left < 0) left = 0;
    if (right > srcLen) right = srcLen;
    const count = right - left;
    starts[i] = left;
    counts[i] = count;

    let sum = 0;
    const base = i * maxCount;
    for (let j = 0; j < count; j++) {
      const w = lanczos((left + j + 0.5 - center) / filterScale);
      weights[base + j] = w;
      sum += w;
    }
    if (sum !== 0) {
      for (let j = 0; j < count; j++) weights[base + j] /= sum;
    }
  }

  return { starts, counts, weights, maxCount };
}

/**
 * Separable Lanczos-3 resample of a planar Float32 RGB image.
 * Horizontal pass first, then vertical, exactly as specified.
 */
export function lanczosResample(
  src: Float32Array,
  srcW: number,
  srcH: number,
  dstW: number,
  dstH: number,
): Float32Array {
  // Horizontal pass: srcW -> dstW
  const hx = buildContributions(srcW, dstW);
  const mid = new Float32Array(dstW * srcH * 3);
  for (let y = 0; y < srcH; y++) {
    const srcRow = y * srcW * 3;
    const dstRow = y * dstW * 3;
    for (let x = 0; x < dstW; x++) {
      const start = hx.starts[x];
      const count = hx.counts[x];
      const base = x * hx.maxCount;
      let r = 0;
      let g = 0;
      let b = 0;
      for (let j = 0; j < count; j++) {
        const w = hx.weights[base + j];
        const p = srcRow + (start + j) * 3;
        r += src[p] * w;
        g += src[p + 1] * w;
        b += src[p + 2] * w;
      }
      const o = dstRow + x * 3;
      mid[o] = r;
      mid[o + 1] = g;
      mid[o + 2] = b;
    }
  }

  // Vertical pass: srcH -> dstH
  const vy = buildContributions(srcH, dstH);
  const out = new Float32Array(dstW * dstH * 3);
  for (let y = 0; y < dstH; y++) {
    const start = vy.starts[y];
    const count = vy.counts[y];
    const base = y * vy.maxCount;
    const dstRow = y * dstW * 3;
    for (let x = 0; x < dstW; x++) {
      let r = 0;
      let g = 0;
      let b = 0;
      for (let j = 0; j < count; j++) {
        const w = vy.weights[base + j];
        const p = ((start + j) * dstW + x) * 3;
        r += mid[p] * w;
        g += mid[p + 1] * w;
        b += mid[p + 2] * w;
      }
      const o = dstRow + x * 3;
      out[o] = r;
      out[o + 1] = g;
      out[o + 2] = b;
    }
  }

  return out;
}

/* ---------- step 2: unsharp mask ---------- */

function gaussianKernel(radius: number): Float32Array {
  const sigma = radius;
  const r = Math.max(1, Math.ceil(sigma * 3));
  const k = new Float32Array(r * 2 + 1);
  let sum = 0;
  const denom = 2 * sigma * sigma;
  for (let i = -r; i <= r; i++) {
    const v = Math.exp(-(i * i) / denom);
    k[i + r] = v;
    sum += v;
  }
  for (let i = 0; i < k.length; i++) k[i] /= sum;
  return k;
}

export function gaussianBlur(
  src: Float32Array,
  w: number,
  h: number,
  radius: number,
): Float32Array {
  if (radius <= 0) return src.slice();
  const k = gaussianKernel(radius);
  const r = (k.length - 1) / 2;

  const tmp = new Float32Array(src.length);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let rr = 0;
      let gg = 0;
      let bb = 0;
      for (let i = -r; i <= r; i++) {
        let sx = x + i;
        if (sx < 0) sx = 0;
        else if (sx >= w) sx = w - 1;
        const wgt = k[i + r];
        const p = (y * w + sx) * 3;
        rr += src[p] * wgt;
        gg += src[p + 1] * wgt;
        bb += src[p + 2] * wgt;
      }
      const o = (y * w + x) * 3;
      tmp[o] = rr;
      tmp[o + 1] = gg;
      tmp[o + 2] = bb;
    }
  }

  const out = new Float32Array(src.length);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let rr = 0;
      let gg = 0;
      let bb = 0;
      for (let i = -r; i <= r; i++) {
        let sy = y + i;
        if (sy < 0) sy = 0;
        else if (sy >= h) sy = h - 1;
        const wgt = k[i + r];
        const p = (sy * w + x) * 3;
        rr += tmp[p] * wgt;
        gg += tmp[p + 1] * wgt;
        bb += tmp[p + 2] * wgt;
      }
      const o = (y * w + x) * 3;
      out[o] = rr;
      out[o + 1] = gg;
      out[o + 2] = bb;
    }
  }
  return out;
}

/**
 * Pillow UnsharpMask(radius, percent, threshold=2) semantics:
 *   diff = img - blurred
 *   out  = |diff| >= 2 ? img + diff * (percent / 100) : img
 */
export function unsharpMask(
  src: Float32Array,
  w: number,
  h: number,
  radius: number,
  percent: number,
): Float32Array {
  if (percent === 0) return src;
  const blurred = gaussianBlur(src, w, h, radius);
  const out = new Float32Array(src.length);
  const amount = percent / 100;
  for (let i = 0; i < src.length; i++) {
    const diff = src[i] - blurred[i];
    out[i] = Math.abs(diff) >= 2 ? src[i] + diff * amount : src[i];
  }
  return out;
}

/* ---------- steps 3-5 ---------- */

function toRgb888(src: Float32Array, gains: [number, number, number] | null): Uint8Array {
  const out = new Uint8Array(src.length);
  const [gR, gG, gB] = gains ?? [1, 1, 1];
  for (let i = 0; i < src.length; i += 3) {
    for (let c = 0; c < 3; c++) {
      // step 3: decode to linear light with the plain 2.2 power curve
      let v = src[i + c];
      if (v < 0) v = 0;
      else if (v > 255) v = 255;
      let lin = Math.pow(v / 255, 2.2);
      // step 4: white balance in linear light, clip to [0,1]
      lin *= c === 0 ? gR : c === 1 ? gG : gB;
      if (lin < 0) lin = 0;
      else if (lin > 1) lin = 1;
      // step 5: re-encode and round
      out[i + c] = encodeLinear(lin);
    }
  }
  return out;
}

/** RGBA (alpha over black) -> planar-interleaved Float32 RGB. */
export function rgbaToRgbFloat(data: Uint8ClampedArray | Uint8Array, w: number, h: number) {
  const out = new Float32Array(w * h * 3);
  for (let i = 0, j = 0; i < w * h * 4; i += 4, j += 3) {
    const a = data[i + 3] / 255;
    out[j] = data[i] * a;
    out[j + 1] = data[i + 1] * a;
    out[j + 2] = data[i + 2] * a;
  }
  return out;
}

function floatToRgb888Raw(src: Float32Array): Uint8Array {
  const out = new Uint8Array(src.length);
  for (let i = 0; i < src.length; i++) {
    const v = src[i];
    out[i] = v <= 0 ? 0 : v >= 255 ? 255 : Math.floor(v + 0.5);
  }
  return out;
}

/**
 * The pipeline. Input RGBA of any size, output N*N*3 RGB888.
 */
export function runPipeline(
  rgba: Uint8ClampedArray | Uint8Array,
  srcW: number,
  srcH: number,
  params: PipelineParams,
): PipelineResult {
  const t0 = Date.now();
  const { size, gains, unsharpRadius, unsharpPercent } = params;

  const rgb = rgbaToRgbFloat(rgba, srcW, srcH);
  const down = lanczosResample(rgb, srcW, srcH, size, size);
  const sharpened = unsharpMask(down, size, size, unsharpRadius, unsharpPercent);

  const unbalanced = toRgb888(sharpened, null);
  const balanced = toRgb888(sharpened, gains);

  return {
    size,
    balanced,
    unbalanced,
    steps: [
      {
        name: "1. Lanczos-3 downscale",
        note: `${srcW}x${srcH} -> ${size}x${size}, separable, a = 3`,
        buffer: floatToRgb888Raw(down),
      },
      {
        name: "2. Unsharp mask",
        note:
          unsharpPercent === 0
            ? "disabled (percent = 0)"
            : `radius ${unsharpRadius}, percent ${unsharpPercent}, threshold 2`,
        buffer: floatToRgb888Raw(sharpened),
      },
      {
        name: "3-5. Gamma 2.2 -> gains -> re-encode",
        note: `linear gains R ${gains[0].toFixed(2)} G ${gains[1].toFixed(2)} B ${gains[2].toFixed(2)}`,
        // Copy: the step list must not alias `balanced`, or the worker's
        // transfer list would contain the same ArrayBuffer twice.
        buffer: balanced.slice(),
      },
    ],
    ms: Date.now() - t0,
  };
}

/** RGB888 -> RGBA ImageData-compatible bytes, with a display-only brightness scale. */
export function rgb888ToRgba(buf: Uint8Array, brightness = 1): Uint8ClampedArray {
  const n = buf.length / 3;
  const out = new Uint8ClampedArray(n * 4);
  for (let i = 0, j = 0; i < n; i++, j += 3) {
    const o = i * 4;
    out[o] = buf[j] * brightness;
    out[o + 1] = buf[j + 1] * brightness;
    out[o + 2] = buf[j + 2] * brightness;
    out[o + 3] = 255;
  }
  return out;
}
