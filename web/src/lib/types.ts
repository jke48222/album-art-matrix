// Shared typed contracts for Album Art Matrix.

export type SourceId =
  | "applemusic"
  | "spotify"
  | "acoustid"
  | "lastfm"
  | "mpris"
  | "manual"
  | "demo";

export type SourceState =
  | "connected"
  | "disconnected"
  | "needs-setup"
  | "needs-bridge"
  | "error"
  | "no-answer";

export interface NowPlaying {
  trackId: string;
  title: string;
  artist: string;
  album: string;
  artUrl: string | null;
  progressMs: number | null;
  durationMs: number | null;
  isPlaying: boolean;
  /** Which sub-tier of the adapter answered, e.g. "Music.app". */
  tier?: string;
}

export interface SourceStatus {
  id: SourceId;
  state: SourceState;
  /** Plain statement of what the source is waiting on, or the error text. */
  detail: string;
  lastPollAt: number | null;
  lastError: string | null;
  lastAnswerTier: string | null;
}

export interface NowPlayingSource {
  id: SourceId;
  label: string;
  /** One-line description shown in the sources list. */
  description: string;
  /** Returns the current track, or null when this source has no answer. */
  getCurrent(config: SourceConfig): Promise<NowPlaying | null>;
  /** Non-fetching status probe: what state is this source in right now? */
  probe(config: SourceConfig): SourceStatus;
}

export interface SourceConfig {
  enabled: boolean;
  order: number;
  config: Record<string, string | number | boolean>;
}

export type SourceConfigMap = Record<SourceId, SourceConfig>;

export interface WbProfile {
  id: string;
  name: string;
  gainR: number;
  gainG: number;
  gainB: number;
  isMeasured: boolean;
  notes: string;
  createdAt: string;
  builtIn?: boolean;
}

export type ViewMode = "grid" | "wall" | "raw" | "split";
export type IdleBehaviour = "black" | "hold" | "dim" | "ambient";
export type WallSize = 64 | 128 | 192;
/** raw = POST the bare RGB888 body; brain = the Pi brain's JSON {px: base64} /frame shape. */
export type PushFormat = "raw" | "brain";

export interface Settings {
  wallSize: WallSize;
  unsharpRadius: number;
  unsharpPercent: number;
  pollSeconds: number;
  brightness: number;
  viewMode: ViewMode;
  showGrid: boolean;
  showSeams: boolean;
  applyWhiteBalance: boolean;
  idleBehaviour: IdleBehaviour;
  activeWbProfileId: string;
  pushEnabled: boolean;
  pushEndpoint: string;
  pushFormat: PushFormat;
  rawZoom: number;
}

export interface HistoryEntry {
  id: string;
  trackId: string;
  title: string;
  artist: string;
  album: string;
  artUrl: string | null;
  thumb: string | null;
  playedAt: number;
  durationMs: number | null;
  source: SourceId;
  sourceTier: string | null;
  settingsSnapshot: Settings & { gainR: number; gainG: number; gainB: number };
}

export interface PipelineParams {
  size: number;
  gains: [number, number, number];
  unsharpRadius: number;
  unsharpPercent: number;
}

export interface PipelineResult {
  size: number;
  /** N*N*3 RGB888, white balanced. */
  balanced: Uint8Array;
  /** N*N*3 RGB888, post-unsharp, pre-white-balance. */
  unbalanced: Uint8Array;
  /** Intermediate steps for the inspectable pipeline chain. */
  steps: { name: string; note: string; buffer: Uint8Array }[];
  ms: number;
}
