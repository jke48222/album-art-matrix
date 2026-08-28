import { useCallback, useEffect, useRef, useState } from "react";
import { runChain } from "./sources/index";
import { useStore } from "./store";
import type { NowPlaying, SourceId, SourceStatus } from "./types";

const REVIEW_TRACKS: Partial<Record<string, NowPlaying>> = {
  playing: {
    trackId: "review:playing",
    title: "Aurora Drift",
    artist: "Nightpanel",
    album: "Aurora Drift",
    artUrl: "demo://190",
    progressMs: 68_000,
    durationMs: 214_000,
    isPlaying: true,
    tier: "design review",
  },
  paused: {
    trackId: "review:paused",
    title: "Emberfall",
    artist: "Slow Circuit",
    album: "Emberfall EP",
    artUrl: "demo://22",
    progressMs: 130_000,
    durationMs: 199_000,
    isPlaying: false,
    tier: "design review",
  },
  "no-artwork": {
    trackId: "review:noart",
    title: "Untitled Take 4",
    artist: "Unreleased",
    album: "",
    artUrl: null,
    progressMs: 12_000,
    durationMs: 320_000,
    isPlaying: true,
    tier: "design review",
  },
  "art-failed": {
    trackId: "review:artfail",
    title: "Broken Link",
    artist: "404",
    album: "Missing Assets",
    artUrl: "https://example.invalid/cover.jpg",
    progressMs: 4_000,
    durationMs: 180_000,
    isPlaying: true,
    tier: "design review",
  },
  "long-names": {
    trackId: "review:long",
    title:
      "A Very Considerably Overlong Track Title That Will Certainly Need Truncating Somewhere Around Here (Extended Remaster Edition)",
    artist:
      "The Extraordinarily Long Named Collective Featuring Several Other Extraordinarily Long Named Guest Artists",
    album: "Album Titles Can Also Run On For An Unreasonable Distance Indeed",
    artUrl: "demo://288",
    progressMs: 30_000,
    durationMs: 600_000,
    isPlaying: true,
    tier: "design review",
  },
  "non-square": {
    trackId: "review:nonsquare",
    title: "Wide Load",
    artist: "Aspect Ratio",
    album: "16:9",
    artUrl: "nonsquare://",
    progressMs: 8_000,
    durationMs: 150_000,
    isPlaying: true,
    tier: "design review",
  },
};

export interface NowPlayingState {
  track: NowPlaying | null;
  answeredBy: SourceId | null;
  statuses: Record<SourceId, SourceStatus>;
  lastPollAt: number | null;
  lastError: string | null;
  polling: boolean;
}

export function useNowPlaying() {
  const { order, sourceConfigs, settings, review, hydrated } = useStore();
  const [state, setState] = useState<NowPlayingState>({
    track: null,
    answeredBy: null,
    statuses: {} as Record<SourceId, SourceStatus>,
    lastPollAt: null,
    lastError: null,
    polling: false,
  });
  const running = useRef(false);

  const poll = useCallback(async () => {
    if (running.current) return;
    running.current = true;
    setState((s) => ({ ...s, polling: true }));
    try {
      const enabled = order.filter((id) => sourceConfigs[id]?.enabled);
      const { answer, answeredBy, statuses } = await runChain(enabled, sourceConfigs);
      const errors = Object.values(statuses).filter((s) => s.state === "error");
      setState({
        track: answer,
        answeredBy,
        statuses,
        lastPollAt: Date.now(),
        lastError: errors.length ? `${errors[0].id}: ${errors[0].detail}` : null,
        polling: false,
      });
    } finally {
      running.current = false;
      setState((s) => ({ ...s, polling: false }));
    }
  }, [order, sourceConfigs]);

  useEffect(() => {
    if (!hydrated) return;
    if (review !== "off") return; // design-review mode never polls
    let timer: ReturnType<typeof setInterval> | null = null;

    const start = () => {
      void poll();
      timer = setInterval(() => {
        void poll();
      }, settings.pollSeconds * 1000);
    };
    const stop = () => {
      if (timer) clearInterval(timer);
      timer = null;
    };
    const onVisibility = () => {
      // Pause polling when the tab is hidden, resume on focus.
      if (document.hidden) stop();
      else if (!timer) start();
    };

    if (!document.hidden) start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [poll, settings.pollSeconds, review, hydrated]);

  if (review !== "off") {
    const forced = REVIEW_TRACKS[review] ?? null;
    const silent = review === "all-silent" || review === "idle-black" || review === "first-run";
    return {
      state: {
        track: silent ? null : forced,
        answeredBy: silent ? null : ("demo" as SourceId),
        statuses: state.statuses,
        lastPollAt: silent ? Date.now() : Date.now(),
        lastError: review === "source-error" ? "applemusic: Bridge unreachable at http://localhost:8787/nowplaying" : null,
        polling: review === "rendering",
      } satisfies NowPlayingState,
      poll,
    };
  }

  return { state, poll };
}
