import type { NowPlaying, NowPlayingSource, SourceConfig } from "../types";
import { status } from "./base";

const KEY = "aam.manual";

export interface ManualEntry {
  title: string;
  artist: string;
  album: string;
  artUrl: string | null;
  setAt: number;
}

export function readManual(): ManualEntry | null {
  if (typeof localStorage === "undefined") return null;
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as ManualEntry) : null;
  } catch {
    return null;
  }
}

export function writeManual(entry: ManualEntry | null) {
  if (entry) localStorage.setItem(KEY, JSON.stringify(entry));
  else localStorage.removeItem(KEY);
}

export const manualSource: NowPlayingSource = {
  id: "manual",
  label: "Manual",
  description: "Drop an image file, paste an image URL, or paste from the clipboard. Always available.",

  probe() {
    const m = readManual();
    if (!m) return status("manual", "no-answer", "No manual image set. Drop one in to use this source.");
    return status("manual", "connected", `Holding “${m.title || "untitled"}”.`);
  },

  async getCurrent(_cfg: SourceConfig): Promise<NowPlaying | null> {
    const m = readManual();
    if (!m || !m.artUrl) return null;
    return {
      trackId: `manual:${m.setAt}`,
      title: m.title || "Manual image",
      artist: m.artist || "—",
      album: m.album || "",
      artUrl: m.artUrl,
      progressMs: null,
      durationMs: null,
      isPlaying: true,
      tier: "manual entry",
    };
  },
};
