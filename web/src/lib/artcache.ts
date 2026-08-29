/** Art fetch + IndexedDB cache keyed by a hash of the URL. Survives reloads. */

import { makeDemoCover, type RgbaImage } from "./patterns";

const DB_NAME = "aam-art";
const STORE = "covers";

export type ArtFailure =
  | { kind: "cors"; message: string }
  | { kind: "notfound"; message: string }
  | { kind: "timeout"; message: string }
  | { kind: "type"; message: string }
  | { kind: "oversized"; message: string }
  | { kind: "unknown"; message: string };

export class ArtError extends Error {
  constructor(public failure: ArtFailure) {
    super(failure.message);
  }
}

export function hashUrl(url: string): string {
  let h = 2166136261;
  for (let i = 0; i < url.length; i++) {
    h ^= url.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(16);
}

function open(): Promise<IDBDatabase> {
  return new Promise((res, rej) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(STORE)) req.result.createObjectStore(STORE);
    };
    req.onsuccess = () => res(req.result);
    req.onerror = () => rej(req.error);
  });
}

async function idbGet(key: string): Promise<Blob | undefined> {
  const db = await open();
  return new Promise((res, rej) => {
    const tx = db.transaction(STORE, "readonly").objectStore(STORE).get(key);
    tx.onsuccess = () => res(tx.result as Blob | undefined);
    tx.onerror = () => rej(tx.error);
  });
}

async function idbPut(key: string, blob: Blob) {
  const db = await open();
  return new Promise<void>((res, rej) => {
    const tx = db.transaction(STORE, "readwrite").objectStore(STORE).put(blob, key);
    tx.onsuccess = () => res();
    tx.onerror = () => rej(tx.error);
  });
}

async function idbDelete(key: string) {
  const db = await open();
  return new Promise<void>((res, rej) => {
    const tx = db.transaction(STORE, "readwrite").objectStore(STORE).delete(key);
    tx.onsuccess = () => res();
    tx.onerror = () => rej(tx.error);
  });
}

export async function cacheStats(): Promise<{ count: number; bytes: number }> {
  try {
    const db = await open();
    return await new Promise((res, rej) => {
      const store = db.transaction(STORE, "readonly").objectStore(STORE);
      const req = store.getAll();
      req.onsuccess = () => {
        const blobs = req.result as Blob[];
        res({ count: blobs.length, bytes: blobs.reduce((a, b) => a + (b.size ?? 0), 0) });
      };
      req.onerror = () => rej(req.error);
    });
  } catch {
    return { count: 0, bytes: 0 };
  }
}

export async function clearCache() {
  const db = await open();
  return new Promise<void>((res, rej) => {
    const tx = db.transaction(STORE, "readwrite").objectStore(STORE).clear();
    tx.onsuccess = () => res();
    tx.onerror = () => rej(tx.error);
  });
}

const MAX_BYTES = 25 * 1024 * 1024;

async function loadImageElement(src: string, crossOrigin: boolean): Promise<HTMLImageElement> {
  return new Promise((res, rej) => {
    const img = new Image();
    if (crossOrigin) img.crossOrigin = "anonymous";
    const timer = setTimeout(
      () => rej(new ArtError({ kind: "timeout", message: "The image took too long to load." })),
      15000,
    );
    img.onload = () => {
      clearTimeout(timer);
      res(img);
    };
    img.onerror = () => {
      clearTimeout(timer);
      rej(
        new ArtError({
          kind: "cors",
          message:
            "The image could not be read cross-origin. Without an Access-Control-Allow-Origin header the canvas is tainted and the pipeline cannot read its pixels.",
        }),
      );
    };
    img.src = src;
  });
}

function toRgba(img: HTMLImageElement | ImageBitmap): RgbaImage {
  const w = "naturalWidth" in img ? img.naturalWidth : img.width;
  const h = "naturalHeight" in img ? img.naturalHeight : img.height;
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  const ctx = c.getContext("2d", { willReadFrequently: true })!;
  ctx.drawImage(img as CanvasImageSource, 0, 0);
  try {
    const data = ctx.getImageData(0, 0, w, h);
    return { data: data.data, width: w, height: h };
  } catch {
    throw new ArtError({
      kind: "cors",
      message: "Canvas was tainted by the remote image, so getImageData threw. The host must allow cross-origin reads.",
    });
  }
}

/** Fetch (or read from cache) and decode a cover into RGBA pixels. */
export async function loadArt(url: string): Promise<RgbaImage> {
  if (url.startsWith("demo://")) {
    return makeDemoCover(Number(url.slice(7)) || 200);
  }
  if (url.startsWith("data:") || url.startsWith("blob:")) {
    return toRgba(await loadImageElement(url, false));
  }

  const key = hashUrl(url);
  const cached = await idbGet(key).catch(() => undefined);
  if (cached) {
    const objectUrl = URL.createObjectURL(cached);
    try {
      return toRgba(await loadImageElement(objectUrl, false));
    } catch {
      // A cached blob that no longer decodes is poison, not a CORS problem:
      // drop it and take the network path below.
      await idbDelete(key).catch(() => undefined);
    } finally {
      URL.revokeObjectURL(objectUrl);
    }
  }

  let res: Response;
  try {
    res = await fetch(url, { mode: "cors" });
  } catch {
    // Fall back to an <img crossOrigin="anonymous"> load; some CDNs allow the image but not fetch.
    return toRgba(await loadImageElement(url, true));
  }
  if (res.status === 404) throw new ArtError({ kind: "notfound", message: "Artwork URL returned 404." });
  if (!res.ok) throw new ArtError({ kind: "unknown", message: `Artwork URL returned HTTP ${res.status}.` });
  const type = res.headers.get("content-type") ?? "";
  const blob = await res.blob();
  if (!type.startsWith("image/") && !blob.type.startsWith("image/")) {
    throw new ArtError({ kind: "type", message: `Response was ${type || "an unknown type"}, not an image.` });
  }
  if (blob.size > MAX_BYTES) {
    throw new ArtError({
      kind: "oversized",
      message: `Artwork is ${(blob.size / 1e6).toFixed(1)} MB, over the ${MAX_BYTES / 1e6} MB limit.`,
    });
  }
  const objectUrl = URL.createObjectURL(blob);
  try {
    const out = toRgba(await loadImageElement(objectUrl, false));
    // Cache only what provably decoded: a corrupt body stored first would
    // permanently break this cover until the cache was cleared by hand.
    await idbPut(key, blob).catch(() => undefined);
    return out;
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}
