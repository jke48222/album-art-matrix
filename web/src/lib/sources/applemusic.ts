import type { NowPlaying, NowPlayingSource, SourceConfig } from "../types";
import { fetchJson, status, TransportError } from "./base";

export const DEFAULT_BRIDGE_URL = "http://localhost:8787/nowplaying";

/** Which side of the Mac reporter answered - the values it actually sends
 * (scripts/mac_reporter.py): a live phone push, the Mac tier ladder, or
 * "Mac: <app>" when another app on the Mac (Spotify, a browser tab on
 * YouTube Music...) was read through its Now Playing. */
export const TIERS: Record<string, string> = {
  "iphone push": "iPhone push (live from the phone)",
  "mac tiers": "Mac tiers (state file, Music.app, MusicKit)",
};

function tierLabel(v: unknown): string {
  if (v == null) return "unreported tier";
  const s = String(v);
  if (s.toLowerCase().startsWith("mac: ")) return `${s} (read from the Mac's Now Playing)`;
  return TIERS[s.toLowerCase()] ?? s;
}

export const appleMusicSource: NowPlayingSource = {
  id: "applemusic",
  label: "Apple Music",
  description:
    "Three tiers on the Mac: companion state file, Music.app over AppleScript, then a MusicKit account query that catches playback on an iPhone.",

  probe(cfg: SourceConfig) {
    const mode = String(cfg.config.mode ?? "bridge");
    if (mode === "direct") {
      return status(
        "applemusic",
        "needs-bridge",
        "Direct mode talks to macOS APIs (AppleScript, MusicKit) that a browser cannot reach. It needs the desktop build; it is unavailable in this browser.",
      );
    }
    const url = String(cfg.config.bridgeUrl ?? "").trim();
    if (!url) {
      return status("applemusic", "needs-setup", "Set the bridge URL of the reporter running on your Mac.");
    }
    return status("applemusic", "disconnected", `Polling ${url}. Not yet contacted.`);
  },

  async getCurrent(cfg: SourceConfig): Promise<NowPlaying | null> {
    const mode = String(cfg.config.mode ?? "bridge");
    if (mode === "direct") {
      throw new TransportError(
        "Direct mode requires the desktop build. This browser cannot call AppleScript or MusicKit.",
        "network",
      );
    }
    const url = String(cfg.config.bridgeUrl ?? DEFAULT_BRIDGE_URL);
    const { status: code, body } = await fetchJson(url);
    if (code === 204) return null;
    if (code >= 400) throw new TransportError(`Bridge returned HTTP ${code}.`, "http", code);
    if (!body || typeof body !== "object") {
      throw new TransportError("Bridge returned a body that is not a now-playing object.", "parse");
    }
    const b = body as Record<string, unknown>;
    // The Mac reporter speaks snake_case (its dataclass), older bridges camelCase.
    const pick = (a: string, c: string) => b[a] ?? b[c];
    const id = pick("trackId", "track_id");
    if (!b.title && !id) {
      throw new TransportError("Bridge response is malformed: it has no title or trackId.", "parse");
    }
    const rawId = String(id ?? `${b.artist ?? ""}-${b.title ?? ""}`);
    const art = pick("artUrl", "art_url");
    const progress = pick("progressMs", "progress_ms");
    const duration = pick("durationMs", "duration_ms");
    const playing = pick("isPlaying", "is_playing");
    return {
      trackId: rawId.startsWith("applemusic:") ? rawId : `applemusic:${rawId}`,
      title: String(b.title ?? "Unknown title"),
      artist: String(b.artist ?? "Unknown artist"),
      album: String(b.album ?? ""),
      artUrl: art ? String(art) : null,
      progressMs: typeof progress === "number" ? progress : null,
      durationMs: typeof duration === "number" ? duration : null,
      isPlaying: playing !== false,
      tier: tierLabel(b.tier),
    };
  },
};
