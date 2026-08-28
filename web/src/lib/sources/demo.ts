import { DEMO_COVERS } from "../patterns";
import type { NowPlaying, NowPlayingSource } from "../types";
import { status } from "./base";

const KEY = "aam.demo.index";

export function demoIndex(): number {
  if (typeof localStorage === "undefined") return 0;
  return Number(localStorage.getItem(KEY) ?? 0) % DEMO_COVERS.length;
}

export function setDemoIndex(i: number) {
  localStorage.setItem(KEY, String(((i % DEMO_COVERS.length) + DEMO_COVERS.length) % DEMO_COVERS.length));
}

export const demoSource: NowPlayingSource = {
  id: "demo",
  label: "Demo",
  description: "Bundled demo covers so the app is completely usable with nothing configured. Clearly demo content.",

  probe() {
    return status("demo", "connected", "Serving bundled demo content. This is not a real now-playing reading.");
  },

  async getCurrent(): Promise<NowPlaying | null> {
    const cover = DEMO_COVERS[demoIndex()];
    return {
      trackId: cover.id,
      title: cover.title,
      artist: cover.artist,
      album: cover.album,
      // Demo art is generated in-process; the pipeline resolves this scheme directly.
      artUrl: `demo://${cover.hue}`,
      progressMs: null,
      durationMs: null,
      isPlaying: true,
      tier: "demo content",
    };
  },
};
