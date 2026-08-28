import type { NowPlaying, NowPlayingSource, SourceConfig } from "../types";
import { fetchJson, status, TransportError } from "./base";

/**
 * Line-in / microphone -> Chromaprint fingerprint -> AcoustID -> MusicBrainz -> Cover Art Archive.
 * The fingerprinting step (Chromaprint/fpcalc) is not something a browser can do natively,
 * so this adapter runs through a local helper. Without it, the adapter reports needs-bridge
 * and never fabricates a match.
 */
export const acoustidSource: NowPlayingSource = {
  id: "acoustid",
  label: "AcoustID (acoustic fingerprint)",
  description:
    "Hears the room: vinyl, CD, radio, a speaker across the house. Fingerprints captured audio and looks it up. No API can take it away.",

  probe(cfg: SourceConfig) {
    const key = String(cfg.config.apiKey ?? "").trim();
    const bridge = String(cfg.config.bridgeUrl ?? "").trim();
    if (!key) {
      return status(
        "acoustid",
        "needs-setup",
        "Enter an AcoustID API key. Capture and fingerprinting still need the local helper below.",
      );
    }
    if (!bridge) {
      return status(
        "acoustid",
        "needs-bridge",
        "Waiting on: a local helper that captures the selected input, runs Chromaprint (fpcalc) and exposes GET /fingerprint. A browser cannot compute a Chromaprint fingerprint natively.",
      );
    }
    return status("acoustid", "disconnected", `Helper configured at ${bridge}. Not yet contacted.`);
  },

  async getCurrent(cfg: SourceConfig): Promise<NowPlaying | null> {
    const key = String(cfg.config.apiKey ?? "").trim();
    const bridge = String(cfg.config.bridgeUrl ?? "").trim();
    if (!key || !bridge) return null;

    const seconds = Number(cfg.config.captureSeconds ?? 8);
    const device = String(cfg.config.device ?? "default");
    const { status: code, body } = await fetchJson(
      `${bridge}?seconds=${seconds}&device=${encodeURIComponent(device)}`,
      {},
      Math.max(8000, seconds * 1000 + 4000),
    );
    if (code === 204) return null;
    if (code >= 400) throw new TransportError(`Fingerprint helper returned HTTP ${code}.`, "http", code);
    const fp = body as any;
    if (!fp?.fingerprint || !fp?.duration) {
      throw new TransportError("Helper response is malformed: expected { fingerprint, duration }.", "parse");
    }

    const lookup = await fetchJson(
      `https://api.acoustid.org/v2/lookup?client=${encodeURIComponent(key)}&meta=recordings+releasegroups&duration=${Math.round(
        fp.duration,
      )}&fingerprint=${encodeURIComponent(fp.fingerprint)}`,
    );
    const r = (lookup.body as any)?.results?.[0];
    const rec = r?.recordings?.[0];
    if (!rec) return null;
    const rg = rec.releasegroups?.[0];
    return {
      trackId: `acoustid:${rec.id}`,
      title: rec.title ?? "Unknown title",
      artist: (rec.artists ?? []).map((a: any) => a.name).join(", ") || "Unknown artist",
      album: rg?.title ?? "",
      artUrl: rg?.id ? `https://coverartarchive.org/release-group/${rg.id}/front-1200` : null,
      progressMs: null,
      durationMs: rec.duration ? rec.duration * 1000 : null,
      isPlaying: true,
      tier: "Chromaprint match",
    };
  },
};
