/** Canvas renderers for the three view modes. Nearest neighbour only, true black off state. */

import { rgb888ToRgba } from "./pipeline";

export const GRID_COLOUR = "rgb(12, 12, 12)";
export const GRID_SCALE = 8;

function bufferToCanvas(buf: Uint8Array, size: number, brightness: number): HTMLCanvasElement {
  const c = document.createElement("canvas");
  c.width = size;
  c.height = size;
  const ctx = c.getContext("2d")!;
  const img = ctx.createImageData(size, size);
  img.data.set(rgb888ToRgba(buf, brightness));
  ctx.putImageData(img, 0, 0);
  return c;
}

/** Nearest-neighbour upscale at an integer factor. */
export function drawNearest(
  target: HTMLCanvasElement,
  buf: Uint8Array,
  size: number,
  scale: number,
  brightness: number,
) {
  target.width = size * scale;
  target.height = size * scale;
  const ctx = target.getContext("2d")!;
  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = "#000000";
  ctx.fillRect(0, 0, target.width, target.height);
  ctx.drawImage(bufferToCanvas(buf, size, brightness), 0, 0, target.width, target.height);
}

/**
 * Preview grid: nearest 8x upscale with a 1-pixel rgb(12,12,12) line every 8 px
 * on both axes, including the outer edges.
 */
export function drawPreviewGrid(
  target: HTMLCanvasElement,
  buf: Uint8Array,
  size: number,
  brightness: number,
  showGrid = true,
) {
  drawNearest(target, buf, size, GRID_SCALE, brightness);
  if (!showGrid) return;
  const ctx = target.getContext("2d")!;
  ctx.fillStyle = GRID_COLOUR;
  const w = target.width;
  const h = target.height;
  for (let x = 0; x <= w; x += GRID_SCALE) ctx.fillRect(Math.min(x, w - 1), 0, 1, h);
  for (let y = 0; y <= h; y += GRID_SCALE) ctx.fillRect(0, Math.min(y, h - 1), w, 1);
}

/**
 * Wall view: discrete round LED emitters on a black field, gap between emitters,
 * diffuser bloom scaled by brightness. Unlit emitters are pure black.
 */
export function drawWall(
  target: HTMLCanvasElement,
  buf: Uint8Array,
  size: number,
  cell: number,
  brightness: number,
  showSeams: boolean,
) {
  target.width = size * cell;
  target.height = size * cell;
  const ctx = target.getContext("2d")!;
  ctx.fillStyle = "#000000";
  ctx.fillRect(0, 0, target.width, target.height);

  const radius = cell * 0.34;
  ctx.globalCompositeOperation = "lighter";

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const i = (y * size + x) * 3;
      const r = buf[i] * brightness;
      const g = buf[i + 1] * brightness;
      const b = buf[i + 2] * brightness;
      if (r < 0.5 && g < 0.5 && b < 0.5) continue; // emits nothing
      const cxp = x * cell + cell / 2;
      const cyp = y * cell + cell / 2;
      const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;

      if (cell >= 4 && lum > 0.02) {
        const bloom = ctx.createRadialGradient(cxp, cyp, radius * 0.4, cxp, cyp, radius + cell * lum * 1.5);
        bloom.addColorStop(0, `rgba(${r | 0}, ${g | 0}, ${b | 0}, ${0.42 * lum})`);
        bloom.addColorStop(1, "rgba(0,0,0,0)");
        ctx.fillStyle = bloom;
        ctx.beginPath();
        ctx.arc(cxp, cyp, radius + cell * lum * 1.5, 0, Math.PI * 2);
        ctx.fill();
      }

      ctx.fillStyle = `rgb(${r | 0}, ${g | 0}, ${b | 0})`;
      ctx.beginPath();
      ctx.arc(cxp, cyp, radius, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  ctx.globalCompositeOperation = "source-over";

  if (showSeams && size > 64) {
    const panels = size / 64;
    ctx.strokeStyle = "rgba(30, 30, 34, 0.9)";
    ctx.lineWidth = Math.max(1, cell * 0.4);
    for (let p = 1; p < panels; p++) {
      const at = p * 64 * cell;
      ctx.beginPath();
      ctx.moveTo(at, 0);
      ctx.lineTo(at, target.height);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(0, at);
      ctx.lineTo(target.width, at);
      ctx.stroke();
    }
  }
}

export function canvasToBlob(canvas: HTMLCanvasElement): Promise<Blob> {
  return new Promise((res, rej) =>
    canvas.toBlob((b) => (b ? res(b) : rej(new Error("Canvas export failed"))), "image/png"),
  );
}

export function download(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function makeScaledPng(buf: Uint8Array, size: number, scale: number, brightness = 1) {
  const c = document.createElement("canvas");
  drawNearest(c, buf, size, scale, brightness);
  return c;
}

/** Side-by-side compare PNG: without WB | with WB, at identical scale. */
export function makeComparePng(
  unbalanced: Uint8Array,
  balanced: Uint8Array,
  size: number,
  scale: number,
): HTMLCanvasElement {
  const gap = 16;
  const w = size * scale;
  const c = document.createElement("canvas");
  c.width = w * 2 + gap;
  c.height = w + 28;
  const ctx = c.getContext("2d")!;
  ctx.fillStyle = "#000000";
  ctx.fillRect(0, 0, c.width, c.height);
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(makeScaledPng(unbalanced, size, scale), 0, 28);
  ctx.drawImage(makeScaledPng(balanced, size, scale), w + gap, 28);
  ctx.fillStyle = "#cfcfcf";
  ctx.font = "16px monospace";
  ctx.fillText("without white balance", 2, 19);
  ctx.fillText("with white balance (looks warm on a monitor — expected)", w + gap + 2, 19);
  return c;
}
