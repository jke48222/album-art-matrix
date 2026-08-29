import { createFileRoute, Link } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { HonestNote, Readout, SectionTitle, StateBadge, Strip } from "@/components/Bits";
import { Dial } from "@/components/Dial";
import { WallCanvas } from "@/components/WallCanvas";
import { useStore, DEFAULT_SETTINGS } from "@/lib/store";
import { useNowPlaying } from "@/lib/useNowPlaying";
import { usePipelineWorker } from "@/lib/usePipeline";
import { loadArt, ArtError } from "@/lib/artcache";
import { makePattern, PATTERNS, type PatternId, type RgbaImage } from "@/lib/patterns";
import { canvasToBlob, download, drawNearest, makeComparePng, makeScaledPng } from "@/lib/render";
import { DEFAULT_POWER } from "@/lib/power";
import { roomLightFromFrame, applyRoomLight } from "@/lib/ambient";
import { tap } from "@/lib/haptics";
import { cn } from "@/lib/utils";
import type { IdleBehaviour, NowPlaying, PipelineResult, ViewMode } from "@/lib/types";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Album Art Matrix - the wall" },
      {
        name: "description",
        content:
          "Whatever is playing, downscaled with Lanczos-3, sharpened, white balanced in linear light, and rendered as a 3x3 wall of 64x64 HUB75 P2.5 LED panels.",
      },
      { property: "og:title", content: "Album Art Matrix - the wall" },
      {
        property: "og:description",
        content: "A phone remote and simulator for a nine-panel RGB LED album art wall.",
      },
    ],
  }),
  component: WallPage,
});

const MODES: { id: ViewMode; label: string; note: string }[] = [
  { id: "wall", label: "Wall", note: "Round emitters on a dark substrate, with bloom. The object in the room." },
  { id: "grid", label: "Grid", note: "One pixel block per LED with the panel grid drawn in. The legibility judge." },
  { id: "raw", label: "Raw", note: "Nearest-neighbour buffer, no styling. What the Pi receives." },
  { id: "split", label: "Split", note: "Drag the seam. Uncorrected on the left, white balanced on the right." },
];

const IDLE_OPTIONS: { id: IdleBehaviour; label: string }[] = [
  { id: "black", label: "Black" },
  { id: "hold", label: "Hold" },
  { id: "dim", label: "Dim" },
  { id: "ambient", label: "Drift" },
];

function fmtMs(ms: number) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

function WallPage() {
  const { settings, setSettings, gains, activeProfile, addHistory, review, hydrated } = useStore();
  const { state, poll } = useNowPlaying();
  const { run, busy } = usePipelineWorker();

  const [result, setResult] = useState<PipelineResult | null>(null);
  const [idleResult, setIdleResult] = useState<PipelineResult | null>(null);
  const [artError, setArtError] = useState<string | null>(null);
  const [pattern, setPattern] = useState<PatternId | null>(null);
  const [step, setStep] = useState<number | null>(null);
  const [override, setOverride] = useState<NowPlaying | null>(null);
  const lastLogged = useRef<string | null>(null);
  const lastGood = useRef<PipelineResult | null>(null);
  const resultFor = useRef<string | null>(null); // which trackId the current result renders
  // what the current result was rendered FROM, so a same-album track change
  // (same artUrl) can claim the existing frame instead of being skipped
  const rendered = useRef<{ url: string; proc: unknown } | null>(null);

  useEffect(() => {
    const raw = sessionStorage.getItem("aam.rerender");
    if (!raw) return;
    sessionStorage.removeItem("aam.rerender");
    try {
      const t = JSON.parse(raw);
      setOverride({ ...t, progressMs: null, durationMs: null, isPlaying: false, tier: "history re-render" });
      toast.success("Re-rendering that track with the current settings.");
    } catch {
      /* ignore malformed */
    }
  }, []);

  const track = override ?? state.track;
  const gainsUsed: [number, number, number] = settings.applyWhiteBalance ? gains : [1, 1, 1];

  const process = useCallback(
    async (img: RgbaImage) => {
      const r = await run(img, {
        size: settings.wallSize,
        gains: gainsUsed,
        unsharpRadius: settings.unsharpRadius,
        unsharpPercent: settings.unsharpPercent,
      });
      setResult(r);
      lastGood.current = r;
      return r;
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [run, settings.wallSize, settings.unsharpRadius, settings.unsharpPercent, gainsUsed[0], gainsUsed[1], gainsUsed[2]],
  );

  // Test pattern takes over the wall until dismissed.
  useEffect(() => {
    if (!pattern) return;
    rendered.current = null; // the art frame is gone; re-render it after
    void process(makePattern(pattern));
  }, [pattern, process]);

  useEffect(() => {
    if (pattern) return;
    const url = track?.artUrl;
    if (!url) {
      setResult(null);
      setArtError(null);
      return;
    }
    let cancelled = false;
    const forTrack = track?.trackId ?? null;
    // Album playback: the next track carries the SAME artUrl, so the frame
    // on the wall is already right. Claim it for this track and skip the
    // recompute - before this, the effect never re-ran (it was keyed on
    // artUrl alone), resultFor stayed on the previous track, and history
    // silently skipped every later track of an album.
    if (rendered.current?.url === url && rendered.current?.proc === process) {
      resultFor.current = forTrack;
      return;
    }
    setArtError(null);
    loadArt(url)
      .then(async (img) => {
        if (cancelled) return;
        await process(img);
        rendered.current = { url, proc: process };
        resultFor.current = forTrack;
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setResult(null);
        setArtError(
          e instanceof ArtError
            ? e.message
            : `The cover could not be loaded: ${e instanceof Error ? e.message : String(e)}`,
        );
      });
    return () => {
      cancelled = true;
    };
  }, [track?.trackId, track?.artUrl, pattern, process]);

  // Idle drift: one generated gradient through the real pipeline, when chosen.
  useEffect(() => {
    if (track || pattern || settings.idleBehaviour !== "ambient") return;
    let cancelled = false;
    void run(makePattern("synthetic"), {
      size: settings.wallSize,
      gains: gainsUsed,
      unsharpRadius: settings.unsharpRadius,
      unsharpPercent: settings.unsharpPercent,
    }).then((r) => {
      if (!cancelled) setIdleResult(r);
    });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [track, pattern, settings.idleBehaviour, settings.wallSize]);

  // Log to history once per track, after ITS frame has actually been rendered
  // (result lags a track change by one pipeline run; resultFor closes the race).
  useEffect(() => {
    if (!track || !result || pattern) return;
    if (resultFor.current !== track.trackId) return;
    if (lastLogged.current === track.trackId) return;
    lastLogged.current = track.trackId;
    addHistory({
      id: `${track.trackId}:${Date.now()}`,
      trackId: track.trackId,
      title: track.title,
      artist: track.artist,
      album: track.album,
      artUrl: track.artUrl,
      thumb: makeScaledPng(result.balanced, result.size, 1).toDataURL("image/png"),
      playedAt: Date.now(),
      durationMs: track.durationMs,
      source: state.answeredBy ?? "manual",
      sourceTier: track.tier ?? null,
      settingsSnapshot: { ...settings, gainR: gainsUsed[0], gainG: gainsUsed[1], gainB: gainsUsed[2] },
    });
  }, [track, result, pattern, addHistory, state.answeredBy, settings, gainsUsed]);

  /* What the wall is actually showing right now, idle behaviour included. */
  const idle = !pattern && !track;
  const shown: PipelineResult | null = pattern
    ? result
    : track
      ? result
      : settings.idleBehaviour === "black"
        ? null
        : settings.idleBehaviour === "ambient"
          ? idleResult
          : lastGood.current;
  const dimFactor = idle && settings.idleBehaviour === "dim" ? 0.2 : 1;
  const brightness = (settings.brightness / 100) * dimFactor;

  // The room takes its light from the frame on the wall, scaled by brightness.
  useEffect(() => {
    if (!shown) {
      applyRoomLight(null);
      return;
    }
    const light = roomLightFromFrame(shown.balanced, shown.size);
    applyRoomLight({ ...light, lit: light.lit * brightness });
    return () => applyRoomLight(null);
  }, [shown, brightness]);

  // Per-frame current draw, from the power page's model. Modelled, never measured.
  const power = useMemo(() => {
    if (!shown) return null;
    let sum = 0;
    for (let i = 0; i < shown.balanced.length; i++) sum += shown.balanced[i];
    const averageLevel = sum / (shown.balanced.length * 255);
    const idlePerPanel = 0.4;
    const fullPerPanel = DEFAULT_POWER.ampsPerPanel;
    const duty = averageLevel * brightness;
    const panels = (settings.wallSize / 64) ** 2;
    const amps = panels * (idlePerPanel + (fullPerPanel - idlePerPanel) * duty);
    return { amps, watts: amps * DEFAULT_POWER.supplyVolts, averageLevel: duty };
  }, [shown, brightness, settings.wallSize]);

  const pushFrame = async () => {
    if (!result) return;
    if (!settings.pushEndpoint.trim()) {
      toast.error("No push endpoint set. Add one in Setup.");
      return;
    }
    try {
      let res: Response;
      if (settings.pushFormat === "brain") {
        if (result.size !== 64) {
          toast.error("The Pi brain takes 64x64 frames only. Set the wall to 1 panel to push.");
          return;
        }
        // The brain white-balances /frame pixels itself, so it must get the
        // UNbalanced buffer - sending `balanced` applied the gains twice and
        // landed over-warm and dim on the wall.
        let bin = "";
        for (let i = 0; i < result.unbalanced.length; i++) bin += String.fromCharCode(result.unbalanced[i]);
        res = await fetch(settings.pushEndpoint, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ px: btoa(bin) }),
        });
      } else {
        res = await fetch(settings.pushEndpoint, {
          method: "POST",
          headers: { "content-type": "application/octet-stream", "x-matrix-size": String(result.size) },
          body: new Uint8Array(result.balanced).buffer as ArrayBuffer,
        });
      }
      if (!res.ok) throw new Error(`wall replied ${res.status}`);
      toast.success(`Frame accepted by the wall (${result.size}x${result.size}).`);
    } catch (e) {
      toast.error(`Frame not delivered: ${e instanceof Error ? e.message : String(e)}.`);
    }
  };

  const downloadBin = () => {
    if (!result) return;
    const blob = new Blob([new Uint8Array(result.balanced)], { type: "application/octet-stream" });
    download(blob, `frame-${result.size}x${result.size}.rgb888.bin`);
    toast.success(`${result.balanced.length.toLocaleString()} bytes, exactly what the renderer eats.`);
  };

  const idleLabel = {
    black: "The wall goes true black. Off is off.",
    hold: "Holding the last cover.",
    dim: "Holding the last cover at 20% light.",
    ambient: "A generated gradient through the real pipeline. Not a cover.",
  }[settings.idleBehaviour];

  const mode: ViewMode = MODES.some((m) => m.id === settings.viewMode) ? settings.viewMode : "wall";

  return (
    <div className="space-y-8">
      {/* ── The wall ─────────────────────────────────────────── */}
      <section className="enter">
        <div className="relative mx-auto max-w-[540px]">
          <div key={`${shown?.size ?? 0}-${track?.trackId ?? pattern ?? "dark"}-${mode}`} className="enter relative">
            {mode === "split" && shown ? (
              <SplitWall
                unbalanced={shown.unbalanced}
                balanced={shown.balanced}
                size={shown.size}
                brightness={brightness}
              />
            ) : (
              <WallCanvas
                buffer={shown?.balanced ?? null}
                size={shown?.size ?? settings.wallSize}
                mode={mode === "split" ? "grid" : mode}
                brightness={brightness}
                showGrid={settings.showGrid}
                showSeams={settings.showSeams}
                rawZoom={settings.rawZoom}
              />
            )}
            {busy && (
              <span className="num pulse-dot absolute right-2 top-2 text-[9px] uppercase tracking-[0.14em] text-muted-foreground">
                rendering
              </span>
            )}
          </div>
          {/* the floor catching the glow */}
          <div aria-hidden className="floorlight pointer-events-none absolute -bottom-16 left-1/2 h-16 w-[130%] -translate-x-1/2" />
        </div>

        <div className="mx-auto mt-7 max-w-[540px] space-y-2">
          <Strip options={MODES.map(({ id, label }) => ({ id, label }))} value={mode} onChange={(v) => setSettings({ viewMode: v })} />
          <p className="num px-0.5 text-[10px] leading-relaxed text-muted-foreground">
            {MODES.find((m) => m.id === mode)?.note}
            {mode === "split" && " The balanced side reads warm on this monitor. That is the point."}
          </p>
          {mode === "split" && shown && (
            <div className="enter grid grid-cols-2 gap-2 pt-1.5">
              {([
                ["uncorrected", shown.unbalanced],
                ["balanced", shown.balanced],
              ] as const).map(([label, buf]) => (
                <figure key={label} className="space-y-1">
                  <PlainCanvas buffer={buf} size={shown.size} brightness={brightness} />
                  <figcaption className="num text-center text-[9px] uppercase tracking-[0.12em] text-muted-foreground">
                    {label}
                  </figcaption>
                </figure>
              ))}
            </div>
          )}
        </div>
      </section>

      {/* ── Now playing placard + instruments ────────────────── */}
      <section className="grid gap-4 md:grid-cols-[1fr_248px]">
        <div className="placard flex min-w-0 flex-col p-5">
          {track ? (
            <NowPlayingPlacard
              key={track.trackId}
              track={track}
              answeredBy={state.answeredBy}
              lastPollAt={state.lastPollAt}
              pipelineMs={result?.ms ?? null}
              polling={state.polling}
              onPoll={() => void poll()}
            />
          ) : (
            <div className="enter">
              <p className="eyebrow">silence</p>
              <p className="display-mid mt-2 text-xl text-foreground">
                {hydrated ? "Nothing is playing." : "Starting up…"}
              </p>
              <p className="mt-1.5 text-xs leading-relaxed text-muted-foreground">
                No source returned a track. {idleLabel}
              </p>
              <div className="mt-4 flex items-center gap-3">
                <Strip
                  options={IDLE_OPTIONS}
                  value={settings.idleBehaviour}
                  onChange={(v) => setSettings({ idleBehaviour: v })}
                  size="sm"
                  className="max-w-[280px] flex-1"
                />
                <button
                  onClick={() => {
                    tap();
                    void poll();
                  }}
                  disabled={state.polling}
                  className="num press shrink-0 rounded-md border border-border px-3 py-2 text-[10px] uppercase tracking-[0.12em] text-muted-foreground hover:text-foreground disabled:opacity-40"
                >
                  {state.polling ? "polling" : "poll now"}
                </button>
              </div>
            </div>
          )}

          {pattern && (
            <div className="hairline-t mt-4 pt-3">
              <p className="num text-[10px] uppercase tracking-[0.12em] text-warning">
                test pattern on the wall / {PATTERNS.find((p) => p.id === pattern)?.label}
              </p>
            </div>
          )}
          {review !== "off" && (
            <div className="mt-4">
              <HonestNote tone="warn">Design-review mode is on. This is a forced state, not a live reading.</HonestNote>
            </div>
          )}
          {(artError || state.lastError) && (
            <div className="mt-4 space-y-2">
              {artError && <HonestNote tone="warn">{artError}</HonestNote>}
              {state.lastError && <HonestNote tone="warn">Last source error - {state.lastError}</HonestNote>}
            </div>
          )}
        </div>

        {/* Instruments */}
        <div className="placard flex flex-col items-stretch gap-4 p-5">
          <div className="flex items-start justify-around gap-2">
            <Dial
              label="light"
              value={settings.brightness}
              min={5}
              max={100}
              step={5}
              onChange={(v) => setSettings({ brightness: v })}
              format={(v) => `${Math.round(v)}%`}
              size={104}
            />
            <div className="flex flex-col items-stretch gap-2 pt-1.5">
              <Strip
                options={[
                  { id: "on", label: "WB" },
                  { id: "off", label: "Raw" },
                ]}
                value={settings.applyWhiteBalance ? "on" : "off"}
                onChange={(v) => setSettings({ applyWhiteBalance: v === "on" })}
                size="sm"
                className="w-[104px]"
              />
              <Strip
                options={[
                  { id: "on", label: "Grid" },
                  { id: "off", label: "Off" },
                ]}
                value={settings.showGrid ? "on" : "off"}
                onChange={(v) => setSettings({ showGrid: v === "on", showSeams: v === "on" })}
                size="sm"
                className="w-[104px]"
              />
            </div>
          </div>

          <div className="hairline-t pt-2">
            <Readout label="profile" value={activeProfile.name.toLowerCase()} />
            <Readout
              label="gains"
              value={`R ${gainsUsed[0].toFixed(2)} / G ${gainsUsed[1].toFixed(2)} / B ${gainsUsed[2].toFixed(2)}`}
              tone={activeProfile.isMeasured || !settings.applyWhiteBalance ? undefined : "warn"}
            />
            {power && (
              <>
                <Readout label="frame draw" value={`${power.amps.toFixed(1)} A / ${power.watts.toFixed(0)} W model`} />
                <Readout label="duty" value={`${(power.averageLevel * 100).toFixed(1)}%`} />
              </>
            )}
            <Readout label="panel" value={`${settings.wallSize}x${settings.wallSize} / ${(settings.wallSize / 64) ** 2}x p2.5`} />
          </div>

          <div className="hairline-t pt-3">
            <p className="eyebrow mb-2">chain</p>
            <Link to="/sources" className="press block space-y-1.5">
              {Object.values(state.statuses)
                .slice(0, 4)
                .map((s) => (
                  <span key={s.id} className="flex items-center justify-between gap-2">
                    <span className="num text-[10px] text-muted-foreground">{s.id}</span>
                    <StateBadge state={s.state} />
                  </span>
                ))}
            </Link>
          </div>
        </div>
      </section>

      {/* ── Pipeline filmstrip ───────────────────────────────── */}
      {result && (
        <section className="space-y-3">
          <SectionTitle eyebrow="every step, inspectable" title="Pipeline" />
          <div className="flex gap-2 overflow-x-auto pb-1">
            {result.steps.map((s, i) => (
              <button
                key={s.name}
                onClick={() => {
                  tap();
                  setStep(step === i ? null : i);
                }}
                className={cn(
                  "press w-24 shrink-0 space-y-1.5 border p-1.5 text-left transition-colors",
                  step === i ? "border-foreground/60 bg-surface" : "border-border hover:border-foreground/30",
                )}
              >
                <StepThumb buffer={s.buffer} size={result.size} />
                <span className="num block truncate text-[9px] uppercase tracking-[0.08em] text-muted-foreground">
                  {s.name}
                </span>
              </button>
            ))}
          </div>
          {step !== null && result.steps[step] && (
            <div className="placard enter space-y-2 p-4">
              <p className="num text-[10px] uppercase tracking-[0.12em] text-foreground">
                {result.steps[step].name}
              </p>
              <p className="text-xs leading-relaxed text-muted-foreground">{result.steps[step].note}</p>
              <StepLarge buffer={result.steps[step].buffer} size={result.size} />
            </div>
          )}
        </section>
      )}

      {/* ── Test patterns ────────────────────────────────────── */}
      <section className="space-y-3">
        <SectionTitle eyebrow="calibration, not playback" title="Test patterns" />
        <div className="grid grid-cols-2 gap-1.5 sm:grid-cols-4">
          {PATTERNS.map((p) => (
            <button
              key={p.id}
              onClick={() => {
                tap();
                setPattern(pattern === p.id ? null : p.id);
              }}
              className={cn(
                "num press border px-3 py-2.5 text-left text-[10px] uppercase tracking-[0.1em] transition-colors",
                pattern === p.id
                  ? "border-foreground bg-foreground text-background"
                  : "border-border text-muted-foreground hover:border-foreground/40 hover:text-foreground",
              )}
            >
              {p.label}
            </button>
          ))}
        </div>
        <p className="num text-[10px] leading-relaxed text-muted-foreground">
          {pattern
            ? PATTERNS.find((p) => p.id === pattern)?.purpose
            : "A pattern takes the wall until dismissed, so calibration never gets confused with playback."}
        </p>
      </section>

      {/* ── Export + push ────────────────────────────────────── */}
      <section className="space-y-3">
        <SectionTitle eyebrow="hardware handoff" title="Export" />
        <div className="grid grid-cols-2 gap-1.5 sm:grid-cols-5">
          <ExportBtn
            disabled={!result}
            onClick={async () => {
              if (!result) return;
              download(await canvasToBlob(makeScaledPng(result.balanced, result.size, 1)), `wall-${result.size}.png`);
            }}
          >
            png 1:1
          </ExportBtn>
          <ExportBtn
            disabled={!result}
            onClick={async () => {
              if (!result) return;
              download(await canvasToBlob(makeScaledPng(result.balanced, result.size, 4)), `wall-${result.size}-4x.png`);
            }}
          >
            png 4x
          </ExportBtn>
          <ExportBtn
            disabled={!result}
            onClick={async () => {
              if (!result) return;
              download(
                await canvasToBlob(makeComparePng(result.unbalanced, result.balanced, result.size, 3)),
                "white-balance-compare.png",
              );
            }}
          >
            compare png
          </ExportBtn>
          <ExportBtn disabled={!result} onClick={downloadBin}>
            rgb888 .bin
          </ExportBtn>
          <ExportBtn disabled={!result || !settings.pushEnabled} onClick={() => void pushFrame()} accent>
            push to wall
          </ExportBtn>
        </div>
        {!settings.pushEnabled && (
          <p className="num text-[10px] text-muted-foreground">
            Push is off. Point it at the Pi brain or any endpoint in Setup.
          </p>
        )}
      </section>
    </div>
  );
}

/* ---------- pieces ---------- */

function NowPlayingPlacard({
  track,
  answeredBy,
  lastPollAt,
  pipelineMs,
  polling,
  onPoll,
}: {
  track: NowPlaying;
  answeredBy: string | null;
  lastPollAt: number | null;
  pipelineMs: number | null;
  polling: boolean;
  onPoll: () => void;
}) {
  // Progress advances locally between polls while playing.
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!track.isPlaying || track.progressMs == null || track.durationMs == null) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [track.isPlaying, track.progressMs, track.durationMs]);

  const elapsed =
    track.progressMs != null
      ? Math.min(
          track.durationMs ?? Infinity,
          track.progressMs + (track.isPlaying && lastPollAt ? now - lastPollAt : 0),
        )
      : null;
  const frac = elapsed != null && track.durationMs ? Math.min(1, elapsed / track.durationMs) : null;

  return (
    <div className="enter flex min-w-0 flex-1 flex-col">
      <div className="flex items-start justify-between gap-3">
        <p className="eyebrow">{track.isPlaying ? "now playing" : "paused"}</p>
        <button
          onClick={onPoll}
          disabled={polling}
          className="num press -mt-0.5 shrink-0 rounded-md border border-border px-2.5 py-1 text-[9px] uppercase tracking-[0.12em] text-muted-foreground hover:text-foreground disabled:opacity-40"
        >
          {polling ? "polling" : "poll"}
        </button>
      </div>
      <h1 className="display-mid mt-2 line-clamp-2 text-2xl leading-tight text-foreground">{track.title}</h1>
      <p className="num mt-1 truncate text-xs text-muted-foreground">
        {track.artist}
        {track.album ? ` - ${track.album}` : ""}
      </p>

      <div className="mt-auto pt-5">
        {frac != null ? (
          <div>
            <div className="relative h-px w-full bg-border">
              <span className="absolute inset-y-0 left-0 -my-px h-[3px] bg-[var(--art)]" style={{ width: `${frac * 100}%` }} />
            </div>
            <div className="num mt-1.5 flex justify-between text-[9px] tracking-[0.08em] text-muted-foreground">
              <span>{elapsed != null ? fmtMs(elapsed) : "-"}</span>
              <span>{track.durationMs ? fmtMs(track.durationMs) : "-"}</span>
            </div>
          </div>
        ) : (
          <div className="h-px w-full bg-border" />
        )}
        <p className="num mt-2 text-[9px] uppercase tracking-[0.1em] text-muted-foreground">
          {answeredBy ?? "override"}
          {track.tier ? ` / ${track.tier}` : ""}
          {lastPollAt ? ` / polled ${new Date(lastPollAt).toLocaleTimeString()}` : ""}
          {pipelineMs != null ? ` / pipeline ${pipelineMs.toFixed(0)} ms` : ""}
        </p>
      </div>
    </div>
  );
}

/* The split hero: drag the seam between uncorrected and balanced. */
function SplitWall({
  unbalanced,
  balanced,
  size,
  brightness,
}: {
  unbalanced: Uint8Array;
  balanced: Uint8Array;
  size: number;
  brightness: number;
}) {
  const [wipe, setWipe] = useState(0.5);
  const host = useRef<HTMLDivElement>(null);
  const aRef = useRef<HTMLCanvasElement>(null);
  const bRef = useRef<HTMLCanvasElement>(null);
  const scale = 8;

  useEffect(() => {
    if (aRef.current) drawNearest(aRef.current, unbalanced, size, scale, brightness);
    if (bRef.current) drawNearest(bRef.current, balanced, size, scale, brightness);
  }, [unbalanced, balanced, size, brightness]);

  const setFromEvent = (e: React.PointerEvent) => {
    const rect = host.current?.getBoundingClientRect();
    if (!rect) return;
    setWipe(Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)));
  };

  return (
    <div
      ref={host}
      className="relative cursor-ew-resize touch-none select-none overflow-hidden bg-black"
      onPointerDown={(e) => {
        (e.target as Element).setPointerCapture(e.pointerId);
        setFromEvent(e);
      }}
      onPointerMove={(e) => e.buttons > 0 && setFromEvent(e)}
      role="slider"
      aria-label="White balance split"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(wipe * 100)}
    >
      <canvas ref={aRef} className="block w-full" style={{ imageRendering: "pixelated" }} />
      <div className="absolute inset-y-0 right-0 overflow-hidden" style={{ left: `${wipe * 100}%` }}>
        <canvas
          ref={bRef}
          className="absolute right-0 top-0 h-full"
          style={{ imageRendering: "pixelated", width: `${100 / (1 - wipe || 1e-6)}%`, maxWidth: "none" }}
        />
      </div>
      <div className="pointer-events-none absolute inset-y-0 w-px bg-[var(--art)]" style={{ left: `${wipe * 100}%` }}>
        <span className="absolute left-1/2 top-1/2 h-6 w-[3px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-[var(--art)]" />
      </div>
      <span className="num pointer-events-none absolute left-2 top-2 text-[9px] uppercase tracking-[0.12em] text-white/60">
        uncorrected
      </span>
      <span className="num pointer-events-none absolute right-2 top-2 text-[9px] uppercase tracking-[0.12em] text-white/60">
        balanced
      </span>
    </div>
  );
}

function ExportBtn({
  children,
  onClick,
  disabled,
  accent,
}: {
  children: React.ReactNode;
  onClick: () => void;
  disabled?: boolean;
  accent?: boolean;
}) {
  return (
    <button
      onClick={() => {
        tap();
        onClick();
      }}
      disabled={disabled}
      className={cn(
        "num press border px-3 py-2.5 text-[10px] uppercase tracking-[0.1em] transition-colors disabled:cursor-not-allowed disabled:opacity-35",
        accent
          ? "border-primary bg-primary text-primary-foreground hover:opacity-90"
          : "border-border text-muted-foreground hover:border-foreground/40 hover:text-foreground",
      )}
    >
      {children}
    </button>
  );
}

function PlainCanvas({ buffer, size, brightness }: { buffer: Uint8Array; size: number; brightness: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (ref.current) drawNearest(ref.current, buffer, size, 4, brightness);
  }, [buffer, size, brightness]);
  return <canvas ref={ref} className="block w-full bg-black" style={{ imageRendering: "pixelated" }} />;
}

function StepThumb({ buffer, size }: { buffer: Uint8Array; size: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (ref.current) drawNearest(ref.current, buffer, size, 1, 1);
  }, [buffer, size]);
  return <canvas ref={ref} className="block aspect-square w-full bg-black" style={{ imageRendering: "pixelated" }} />;
}

function StepLarge({ buffer, size }: { buffer: Uint8Array; size: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (ref.current) drawNearest(ref.current, buffer, size, size > 128 ? 2 : 4, 1);
  }, [buffer, size]);
  return <canvas ref={ref} className="block w-full max-w-[420px] bg-black" style={{ imageRendering: "pixelated" }} />;
}
