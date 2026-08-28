import type { NowPlaying, NowPlayingSource, SourceConfigMap, SourceId, SourceStatus } from "../types";
import { acoustidSource } from "./acoustid";
import { appleMusicSource, DEFAULT_BRIDGE_URL } from "./applemusic";
import { demoSource } from "./demo";
import { lastfmSource } from "./lastfm";
import { manualSource } from "./manual";
import { mprisSource } from "./mpris";
import { spotifySource } from "./spotify";

export const SOURCES: Record<SourceId, NowPlayingSource> = {
  applemusic: appleMusicSource,
  spotify: spotifySource,
  acoustid: acoustidSource,
  lastfm: lastfmSource,
  mpris: mprisSource,
  manual: manualSource,
  demo: demoSource,
};

export const DEFAULT_ORDER: SourceId[] = [
  "applemusic",
  "spotify",
  "acoustid",
  "lastfm",
  "mpris",
  "manual",
  "demo",
];

export const DEFAULT_SOURCE_CONFIG: SourceConfigMap = {
  applemusic: { enabled: true, order: 0, config: { mode: "bridge", bridgeUrl: DEFAULT_BRIDGE_URL } },
  spotify: { enabled: true, order: 1, config: { clientId: "" } },
  acoustid: { enabled: true, order: 2, config: { apiKey: "", bridgeUrl: "", device: "default", captureSeconds: 8 } },
  lastfm: { enabled: true, order: 3, config: { username: "", apiKey: "" } },
  mpris: { enabled: true, order: 4, config: { bridgeUrl: "" } },
  manual: { enabled: true, order: 5, config: {} },
  demo: { enabled: true, order: 6, config: {} },
};

export interface ChainResult {
  answer: NowPlaying | null;
  answeredBy: SourceId | null;
  statuses: Record<SourceId, SourceStatus>;
}

/**
 * Thin ordered runner over the NowPlayingSource interface.
 * First source with an answer wins. An erroring source is logged and skipped, never fatal.
 */
export async function runChain(order: SourceId[], configs: SourceConfigMap): Promise<ChainResult> {
  const statuses = {} as Record<SourceId, SourceStatus>;
  let answer: NowPlaying | null = null;
  let answeredBy: SourceId | null = null;
  const now = Date.now();

  for (const id of order) {
    const source = SOURCES[id];
    const cfg = configs[id];
    if (!source || !cfg) continue;
    const probe = source.probe(cfg);
    if (!cfg.enabled) {
      statuses[id] = { ...probe, state: "disconnected", detail: "Disabled by you." };
      continue;
    }
    if (probe.state === "needs-setup" || probe.state === "needs-bridge") {
      statuses[id] = probe;
      continue;
    }
    if (answer) {
      statuses[id] = { ...probe, detail: `${probe.detail} Not polled: an earlier source answered.` };
      continue;
    }
    try {
      const result = await source.getCurrent(cfg);
      if (result) {
        answer = result;
        answeredBy = id;
        statuses[id] = {
          ...probe,
          state: "connected",
          detail: `Answered${result.tier ? ` by: ${result.tier}` : ""}.`,
          lastPollAt: now,
          lastAnswerTier: result.tier ?? null,
        };
      } else {
        statuses[id] = { ...probe, state: "no-answer", detail: "Working, nothing playing.", lastPollAt: now };
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.warn(`[source:${id}]`, message);
      statuses[id] = { ...probe, state: "error", detail: message, lastError: message, lastPollAt: now };
    }
  }

  for (const id of DEFAULT_ORDER) {
    if (!statuses[id]) statuses[id] = SOURCES[id].probe(configs[id] ?? { enabled: false, order: 99, config: {} });
  }

  return { answer, answeredBy, statuses };
}
