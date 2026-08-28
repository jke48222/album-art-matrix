import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { DEFAULT_ORDER, DEFAULT_SOURCE_CONFIG } from "./sources/index";
import type {
  HistoryEntry,
  Settings,
  SourceConfigMap,
  SourceId,
  WbProfile,
} from "./types";

export const DEFAULT_GAINS: [number, number, number] = [1.0, 0.75, 0.55];

export const BUILTIN_PROFILE: WbProfile = {
  id: "builtin-typical",
  name: "Typical (unmeasured)",
  gainR: 1.0,
  gainG: 0.75,
  gainB: 0.55,
  isMeasured: false,
  notes:
    "Published typical values for RGB LED panels, not a measurement of any panel. Green and blue emitters are more efficient than red, so uncorrected white reads cyan.",
  createdAt: "2026-01-01T00:00:00.000Z",
  builtIn: true,
};

export const DEFAULT_SETTINGS: Settings = {
  wallSize: 64,
  unsharpRadius: 1.0,
  unsharpPercent: 60,
  pollSeconds: 5,
  brightness: 100,
  viewMode: "grid",
  showGrid: true,
  showSeams: true,
  applyWhiteBalance: true,
  idleBehaviour: "black",
  activeWbProfileId: BUILTIN_PROFILE.id,
  pushEnabled: false,
  pushEndpoint: "",
  pushFormat: "raw",
  rawZoom: 4,
};

function load<T>(key: string, fallback: T): T {
  if (typeof localStorage === "undefined") return fallback;
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw);
    return Array.isArray(fallback) ? parsed : { ...fallback, ...parsed };
  } catch {
    return fallback;
  }
}

function save(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* quota */
  }
}

export type ReviewState =
  | "off"
  | "playing"
  | "paused"
  | "no-artwork"
  | "art-failed"
  | "source-error"
  | "all-silent"
  | "idle-black"
  | "rendering"
  | "first-run"
  | "empty-history"
  | "long-names"
  | "non-square";

export const REVIEW_STATES: { id: ReviewState; label: string }[] = [
  { id: "off", label: "Off (live)" },
  { id: "playing", label: "Playing" },
  { id: "paused", label: "Paused" },
  { id: "no-artwork", label: "No artwork" },
  { id: "art-failed", label: "Artwork failed to load" },
  { id: "source-error", label: "Source error" },
  { id: "all-silent", label: "All sources silent" },
  { id: "idle-black", label: "Idle / black wall" },
  { id: "rendering", label: "Pipeline mid-render" },
  { id: "first-run", label: "First-run empty state" },
  { id: "empty-history", label: "Empty history" },
  { id: "long-names", label: "Long track + artist names" },
  { id: "non-square", label: "Non-square source image" },
];

interface Store {
  settings: Settings;
  setSettings: (patch: Partial<Settings>) => void;
  resetSettings: () => void;
  profiles: WbProfile[];
  activeProfile: WbProfile;
  gains: [number, number, number];
  addProfile: (p: WbProfile) => void;
  deleteProfile: (id: string) => void;
  setActiveProfile: (id: string) => void;
  setActiveGains: (g: [number, number, number]) => void;
  sourceConfigs: SourceConfigMap;
  setSourceConfig: (id: SourceId, patch: Partial<SourceConfigMap[SourceId]>) => void;
  order: SourceId[];
  moveSource: (id: SourceId, dir: -1 | 1) => void;
  history: HistoryEntry[];
  addHistory: (e: HistoryEntry) => void;
  deleteHistory: (id: string) => void;
  clearHistory: () => void;
  review: ReviewState;
  setReview: (r: ReviewState) => void;
  hydrated: boolean;
}

const Ctx = createContext<Store | null>(null);

export function StoreProvider({ children }: { children: ReactNode }) {
  const [hydrated, setHydrated] = useState(false);
  const [settings, setSettingsState] = useState<Settings>(DEFAULT_SETTINGS);
  const [profiles, setProfiles] = useState<WbProfile[]>([BUILTIN_PROFILE]);
  const [sourceConfigs, setSourceConfigs] = useState<SourceConfigMap>(DEFAULT_SOURCE_CONFIG);
  const [order, setOrder] = useState<SourceId[]>(DEFAULT_ORDER);
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [review, setReview] = useState<ReviewState>("off");

  useEffect(() => {
    setSettingsState(load("aam.settings", DEFAULT_SETTINGS));
    const loadedProfiles = load<WbProfile[]>("aam.profiles", []);
    setProfiles([BUILTIN_PROFILE, ...loadedProfiles.filter((p) => !p.builtIn)]);
    setSourceConfigs(load("aam.sourceConfigs", DEFAULT_SOURCE_CONFIG));
    const savedOrder = load<SourceId[]>("aam.order", []);
    setOrder(savedOrder.length ? savedOrder : DEFAULT_ORDER);
    setHistory(load<HistoryEntry[]>("aam.history", []));
    setHydrated(true);
  }, []);

  const setSettings = useCallback((patch: Partial<Settings>) => {
    setSettingsState((prev) => {
      const next = { ...prev, ...patch };
      save("aam.settings", next);
      return next;
    });
  }, []);

  const resetSettings = useCallback(() => {
    setSettingsState(DEFAULT_SETTINGS);
    save("aam.settings", DEFAULT_SETTINGS);
  }, []);

  const activeProfile = useMemo(
    () => profiles.find((p) => p.id === settings.activeWbProfileId) ?? BUILTIN_PROFILE,
    [profiles, settings.activeWbProfileId],
  );

  const gains = useMemo(
    () => [activeProfile.gainR, activeProfile.gainG, activeProfile.gainB] as [number, number, number],
    [activeProfile],
  );

  const persistProfiles = (next: WbProfile[]) => {
    setProfiles(next);
    save("aam.profiles", next.filter((p) => !p.builtIn));
  };

  const addProfile = useCallback(
    (p: WbProfile) => {
      persistProfiles([...profiles.filter((x) => x.id !== p.id), p]);
    },
    [profiles],
  );

  const deleteProfile = useCallback(
    (id: string) => {
      persistProfiles(profiles.filter((p) => p.id !== id || p.builtIn));
      if (settings.activeWbProfileId === id) setSettings({ activeWbProfileId: BUILTIN_PROFILE.id });
    },
    [profiles, settings.activeWbProfileId, setSettings],
  );

  const setActiveProfile = useCallback((id: string) => setSettings({ activeWbProfileId: id }), [setSettings]);

  /** Editing gains live writes to the active profile, creating a working copy for the built-in. */
  const setActiveGains = useCallback(
    (g: [number, number, number]) => {
      if (activeProfile.builtIn) {
        const working: WbProfile = {
          id: "working",
          name: "Working (unsaved)",
          gainR: g[0],
          gainG: g[1],
          gainB: g[2],
          isMeasured: false,
          notes: "Live edits from the controls. Save it as a profile to keep it.",
          createdAt: new Date().toISOString(),
        };
        persistProfiles([...profiles.filter((p) => p.id !== "working"), working]);
        setSettings({ activeWbProfileId: "working" });
      } else {
        persistProfiles(
          profiles.map((p) => (p.id === activeProfile.id ? { ...p, gainR: g[0], gainG: g[1], gainB: g[2] } : p)),
        );
      }
    },
    [activeProfile, profiles, setSettings],
  );

  const setSourceConfig = useCallback((id: SourceId, patch: Partial<SourceConfigMap[SourceId]>) => {
    setSourceConfigs((prev) => {
      const next = {
        ...prev,
        [id]: { ...prev[id], ...patch, config: { ...prev[id].config, ...(patch.config ?? {}) } },
      };
      save("aam.sourceConfigs", next);
      return next;
    });
  }, []);

  const moveSource = useCallback((id: SourceId, dir: -1 | 1) => {
    setOrder((prev) => {
      const i = prev.indexOf(id);
      const j = i + dir;
      if (i < 0 || j < 0 || j >= prev.length) return prev;
      const next = [...prev];
      next[i] = prev[j];
      next[j] = prev[i];
      save("aam.order", next);
      return next;
    });
  }, []);

  const addHistory = useCallback((e: HistoryEntry) => {
    setHistory((prev) => {
      if (prev[0]?.trackId === e.trackId) return prev;
      const next = [e, ...prev].slice(0, 500);
      save("aam.history", next);
      return next;
    });
  }, []);

  const deleteHistory = useCallback((id: string) => {
    setHistory((prev) => {
      const next = prev.filter((e) => e.id !== id);
      save("aam.history", next);
      return next;
    });
  }, []);

  const clearHistory = useCallback(() => {
    setHistory([]);
    save("aam.history", []);
  }, []);

  const value: Store = {
    settings,
    setSettings,
    resetSettings,
    profiles,
    activeProfile,
    gains,
    addProfile,
    deleteProfile,
    setActiveProfile,
    setActiveGains,
    sourceConfigs,
    setSourceConfig,
    order,
    moveSource,
    history: review === "empty-history" ? [] : history,
    addHistory,
    deleteHistory,
    clearHistory,
    review,
    setReview,
    hydrated,
  };

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useStore(): Store {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useStore must be used inside StoreProvider");
  return ctx;
}

/** config.toml emitter, exact hardware-project format. */
export function toConfigToml(settings: Settings, gains: [number, number, number], adapters: SourceId[]) {
  return `[panel]
width = ${settings.wallSize}
height = ${settings.wallSize}

[whitebalance]
r = ${gains[0].toFixed(2)}
g = ${gains[1].toFixed(2)}
b = ${gains[2].toFixed(2)}

[pipeline]
unsharp_radius = ${settings.unsharpRadius.toFixed(1)}
unsharp_percent = ${Math.round(settings.unsharpPercent)}

[nowplaying]
adapters = [${adapters.map((a) => `"${a}"`).join(", ")}]
poll_seconds = ${settings.pollSeconds.toFixed(1)}
`;
}
