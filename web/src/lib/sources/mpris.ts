import type { NowPlaying, NowPlayingSource, SourceConfig } from "../types";
import { fetchJson, status, TransportError } from "./base";

export const MPRIS_CAVEAT =
  "Known caveat: the macOS equivalent path (nowplaying-cli) broke when Apple restricted the private MediaRemote framework around macOS 15.4, and is unverified. Not a bug to fix here.";

export const mprisSource: NowPlayingSource = {
  id: "mpris",
  label: "Local player (MPRIS)",
  description: "MPRIS / D-Bus via playerctl on Linux — whatever desktop player is running.",

  probe(cfg: SourceConfig) {
    const bridge = String(cfg.config.bridgeUrl ?? "").trim();
    if (!bridge) {
      return status(
        "mpris",
        "needs-bridge",
        "Waiting on: a local helper that shells out to playerctl over D-Bus and exposes GET /mpris. A browser has no D-Bus access.",
      );
    }
    return status("mpris", "disconnected", `Helper configured at ${bridge}. Not yet contacted.`);
  },

  async getCurrent(cfg: SourceConfig): Promise<NowPlaying | null> {
    const bridge = String(cfg.config.bridgeUrl ?? "").trim();
    if (!bridge) return null;
    const { status: code, body } = await fetchJson(bridge);
    if (code === 204) return null;
    if (code >= 400) throw new TransportError(`MPRIS helper returned HTTP ${code}.`, "http", code);
    const b = body as any;
    if (!b?.title) throw new TransportError("MPRIS helper response is malformed: no title.", "parse");
    return {
      trackId: `mpris:${b.trackId ?? `${b.artist}-${b.title}`}`,
      title: b.title,
      artist: b.artist ?? "Unknown artist",
      album: b.album ?? "",
      artUrl: b.artUrl ?? null,
      progressMs: b.progressMs ?? null,
      durationMs: b.durationMs ?? null,
      isPlaying: b.isPlaying !== false,
      tier: b.player ? `playerctl: ${b.player}` : "playerctl",
    };
  },
};
