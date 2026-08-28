import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useMemo, useState } from "react";
import { ArrowDown, ArrowUp, Clipboard, RefreshCw, Upload } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { Field, HonestNote, StateBadge } from "@/components/Bits";
import { useStore } from "@/lib/store";
import { SOURCES } from "@/lib/sources/index";
import { DEFAULT_BRIDGE_URL } from "@/lib/sources/applemusic";
import { MPRIS_CAVEAT } from "@/lib/sources/mpris";
import { beginSpotifyAuth, completeSpotifyAuth, disconnectSpotify, readTokens } from "@/lib/sources/spotify";
import { readManual, writeManual } from "@/lib/sources/manual";
import { DEMO_COVERS } from "@/lib/patterns";
import { demoIndex, setDemoIndex } from "@/lib/sources/demo";
import { useNowPlaying } from "@/lib/useNowPlaying";
import type { SourceId } from "@/lib/types";

export const Route = createFileRoute("/sources")({
  head: () => ({
    meta: [
      { title: "Now-playing sources — Album Art Matrix" },
      {
        name: "description",
        content:
          "A priority-ordered source chain: Apple Music, Spotify PKCE, AcoustID, Last.fm, MPRIS, manual and demo — each honest about its state.",
      },
      { property: "og:title", content: "Now-playing sources — Album Art Matrix" },
      {
        property: "og:description",
        content: "Reorder, enable and configure the now-playing source chain. No source ever invents a track.",
      },
    ],
  }),
  component: SourcesPage,
});

function SourcesPage() {
  const { order, moveSource, sourceConfigs, setSourceConfig } = useStore();
  const { state, poll } = useNowPlaying();
  const [manual, setManual] = useState(() => readManual());
  const [tokens, setTokens] = useState<ReturnType<typeof readTokens>>(null);

  useEffect(() => {
    setTokens(readTokens());
    const code = new URLSearchParams(window.location.search).get("code");
    if (code) {
      const clientId = String(sourceConfigs.spotify?.config.clientId ?? "");
      completeSpotifyAuth(clientId, code)
        .then((t) => {
          setTokens(t);
          toast.success("Spotify connected.");
          window.history.replaceState({}, "", "/sources");
        })
        .catch((e) => toast.error(String(e.message ?? e)));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const statuses = state.statuses;

  return (
    <div className="space-y-6">
      <header className="enter flex flex-wrap items-end justify-between gap-3">
        <div className="min-w-0 space-y-1.5">
          <p className="eyebrow">the chain, tried top first</p>
          <h1 className="display-mid text-2xl text-foreground">Sources</h1>
          <p className="max-w-xl text-xs leading-relaxed text-muted-foreground">
            The first source that returns an answer wins. A source that errors is logged and skipped, never fatal,
            and never invents a track.
          </p>
        </div>
        <Button variant="secondary" onClick={() => void poll()}>
          <RefreshCw /> Poll now
        </Button>
      </header>

      <div className="space-y-4">
        {order.map((id, i) => {
          const source = SOURCES[id];
          const cfg = sourceConfigs[id];
          const status = statuses[id] ?? source.probe(cfg);
          const answered = state.answeredBy === id;
          return (
            <Card key={id} className={answered ? "border-[var(--art)]" : undefined}>
              <CardHeader className="gap-2">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="num text-lg text-muted-foreground/50">{String(i + 1).padStart(2, "0")}</span>
                  <CardTitle className="text-base">{source.label}</CardTitle>
                  <StateBadge state={status.state} />
                  {answered && (
                    <span className="num rounded-sm border border-[var(--art)] px-1.5 py-0.5 text-[9px] uppercase tracking-[0.12em] text-[var(--art)]">
                      answered this poll
                    </span>
                  )}
                  <div className="ml-auto flex items-center gap-1">
                    <Button size="icon" variant="ghost" className="h-8 w-8" onClick={() => moveSource(id, -1)}>
                      <ArrowUp className="h-4 w-4" />
                    </Button>
                    <Button size="icon" variant="ghost" className="h-8 w-8" onClick={() => moveSource(id, 1)}>
                      <ArrowDown className="h-4 w-4" />
                    </Button>
                    <Switch
                      checked={cfg.enabled}
                      onCheckedChange={(v) => setSourceConfig(id, { enabled: v })}
                      aria-label={`Enable ${source.label}`}
                    />
                  </div>
                </div>
                <p className="text-xs leading-relaxed text-muted-foreground">{source.description}</p>
                <p className="text-xs leading-relaxed">
                  <span className="text-muted-foreground">Status: </span>
                  {status.detail}
                </p>
                {status.lastAnswerTier && (
                  <p className="num text-[11px] text-muted-foreground">answered by: {status.lastAnswerTier}</p>
                )}
              </CardHeader>
              <CardContent className="space-y-4">
                <SourceSettings id={id} />
                {id === "spotify" && (
                  <div className="flex flex-wrap items-center gap-2">
                    {tokens ? (
                      <>
                        <span className="text-xs text-muted-foreground">
                          Connected{tokens.displayName ? ` as ${tokens.displayName}` : ""}
                        </span>
                        <Button
                          size="sm"
                          variant="secondary"
                          onClick={() => {
                            disconnectSpotify();
                            setTokens(null);
                            toast.success("Spotify disconnected.");
                          }}
                        >
                          Disconnect
                        </Button>
                      </>
                    ) : (
                      <Button
                        size="sm"
                        disabled={!String(cfg.config.clientId ?? "").trim()}
                        onClick={() => void beginSpotifyAuth(String(cfg.config.clientId))}
                      >
                        Connect with PKCE
                      </Button>
                    )}
                  </div>
                )}
                {id === "manual" && <ManualPanel manual={manual} onChange={setManual} />}
                {id === "demo" && <DemoPanel />}
              </CardContent>
            </Card>
          );
        })}
      </div>
    </div>
  );
}

function SourceSettings({ id }: { id: SourceId }) {
  const { sourceConfigs, setSourceConfig } = useStore();
  const cfg = sourceConfigs[id];
  const setCfg = (patch: Record<string, string | number | boolean>) => setSourceConfig(id, { config: patch });

  if (id === "applemusic") {
    const mode = String(cfg.config.mode ?? "bridge");
    return (
      <div className="space-y-3">
        <div className="flex flex-wrap gap-2">
          {(
            [
              { v: "bridge", label: "Bridge mode (works today)" },
              { v: "direct", label: "Direct mode (desktop build only)" },
            ] as const
          ).map((o) => (
            <Button
              key={o.v}
              size="sm"
              variant={mode === o.v ? "default" : "secondary"}
              onClick={() => setCfg({ mode: o.v })}
            >
              {o.label}
            </Button>
          ))}
        </div>
        {mode === "direct" ? (
          <HonestNote tone="warn">
            Direct mode drives AppleScript and MusicKit on macOS directly. A browser cannot reach either, so it is
            unavailable here. It is a real option in the desktop build — it is not hidden and it is not faked.
          </HonestNote>
        ) : (
          <>
            <Field
              label="Bridge URL"
              hint="Run the small reporter on your Mac; it serves GET /nowplaying — 200 with the track, 204 when there is nothing to show. Point this at http://your-mac.local:8787/nowplaying to reach the Mac from a phone on the same network."
            >
              <Input
                className="num"
                value={String(cfg.config.bridgeUrl ?? "")}
                placeholder={DEFAULT_BRIDGE_URL}
                onChange={(e) => setCfg({ bridgeUrl: e.target.value })}
              />
            </Field>
            <HonestNote>
              Tiers, in order: companion state file → Music.app over AppleScript (real-time local playback including
              AirPlay from the Mac, never launches Music) → MusicKit account query (most recently played across all
              devices, which is what catches an iPhone). Artwork is always URL-based so it caches by URL. If the
              browser blocks the response, the local server must send an <code>Access-Control-Allow-Origin</code> header.
            </HonestNote>
          </>
        )}
      </div>
    );
  }

  if (id === "spotify") {
    return (
      <div className="space-y-3">
        <Field
          label="Spotify Client ID"
          hint="Yours, stored on this device only. Authorization Code with PKCE — there is no client secret anywhere in this app. Add this page's URL as a redirect URI in your Spotify app settings."
        >
          <Input
            className="num"
            value={String(cfg.config.clientId ?? "")}
            onChange={(e) => setCfg({ clientId: e.target.value.trim() })}
            placeholder="4uLU6hMCjMI75M1A2tKUQC"
          />
        </Field>
        <p className="num text-[11px] text-muted-foreground">
          Scopes: user-read-currently-playing, user-read-playback-state
        </p>
      </div>
    );
  }

  if (id === "acoustid") {
    return (
      <div className="space-y-3">
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label="AcoustID API key">
            <Input className="num" value={String(cfg.config.apiKey ?? "")} onChange={(e) => setCfg({ apiKey: e.target.value.trim() })} />
          </Field>
          <Field label="Input device">
            <Input
              className="num"
              value={String(cfg.config.device ?? "default")}
              onChange={(e) => setCfg({ device: e.target.value })}
              placeholder="line-in / default"
            />
          </Field>
          <Field label="Capture window (s)">
            <Input
              type="number"
              className="num"
              value={Number(cfg.config.captureSeconds ?? 8)}
              onChange={(e) => setCfg({ captureSeconds: Number(e.target.value) || 8 })}
            />
          </Field>
        </div>
        <Field label="Fingerprint helper URL" hint="A local helper that captures the input, runs Chromaprint (fpcalc) and serves GET /fingerprint.">
          <Input className="num" value={String(cfg.config.bridgeUrl ?? "")} onChange={(e) => setCfg({ bridgeUrl: e.target.value })} placeholder="http://localhost:8788/fingerprint" />
        </Field>
        <HonestNote tone="warn">
          Waiting on: Chromaprint fingerprinting, which a browser cannot do natively. Until the helper is configured
          and reachable, this source stays in needs-bridge and returns nothing. It will never fabricate a match. The
          chain after that is AcoustID → MusicBrainz recording → Cover Art Archive artwork, free and up to 1200x1200.
        </HonestNote>
      </div>
    );
  }

  if (id === "lastfm") {
    return (
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Last.fm username">
          <Input className="num" value={String(cfg.config.username ?? "")} onChange={(e) => setCfg({ username: e.target.value.trim() })} />
        </Field>
        <Field label="Last.fm API key" hint="Stored on this device only.">
          <Input className="num" value={String(cfg.config.apiKey ?? "")} onChange={(e) => setCfg({ apiKey: e.target.value.trim() })} />
        </Field>
      </div>
    );
  }

  if (id === "mpris") {
    return (
      <div className="space-y-3">
        <Field label="playerctl helper URL" hint="A local helper that queries MPRIS over D-Bus and serves GET /mpris.">
          <Input className="num" value={String(cfg.config.bridgeUrl ?? "")} onChange={(e) => setCfg({ bridgeUrl: e.target.value })} placeholder="http://localhost:8789/mpris" />
        </Field>
        <HonestNote tone="warn">{MPRIS_CAVEAT}</HonestNote>
      </div>
    );
  }

  return null;
}

function ManualPanel({
  manual,
  onChange,
}: {
  manual: ReturnType<typeof readManual>;
  onChange: (m: ReturnType<typeof readManual>) => void;
}) {
  const [url, setUrl] = useState("");
  const [meta, setMeta] = useState({ title: manual?.title ?? "", artist: manual?.artist ?? "", album: manual?.album ?? "" });

  const commit = (artUrl: string) => {
    const entry = { ...meta, artUrl, setAt: Date.now() };
    writeManual(entry);
    onChange(entry);
    toast.success("Manual image set. It is now this source's answer.");
  };

  const fromFile = (file: File) => {
    const reader = new FileReader();
    reader.onload = () => commit(String(reader.result));
    reader.readAsDataURL(file);
  };

  return (
    <div className="space-y-3">
      <div
        onDragOver={(e) => e.preventDefault()}
        onDrop={(e) => {
          e.preventDefault();
          const f = e.dataTransfer.files[0];
          if (f) fromFile(f);
        }}
        onPaste={(e) => {
          const item = Array.from(e.clipboardData.items).find((i) => i.type.startsWith("image/"));
          const f = item?.getAsFile();
          if (f) fromFile(f);
        }}
        tabIndex={0}
        className="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border p-6 text-center text-sm text-muted-foreground"
      >
        <Upload className="h-5 w-5" />
        <p>Drop an image here, or focus this box and paste one from the clipboard.</p>
        <label className="cursor-pointer text-primary underline underline-offset-4">
          choose a file
          <input
            type="file"
            accept="image/*"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) fromFile(f);
            }}
          />
        </label>
      </div>
      <div className="flex gap-2">
        <Input className="num" placeholder="https://…/cover.jpg" value={url} onChange={(e) => setUrl(e.target.value)} />
        <Button variant="secondary" onClick={() => url && commit(url)}>
          <Clipboard className="mr-2 h-4 w-4" /> Use URL
        </Button>
      </div>
      <div className="grid gap-3 sm:grid-cols-3">
        {(["title", "artist", "album"] as const).map((k) => (
          <Field key={k} label={k[0].toUpperCase() + k.slice(1)}>
            <Input
              value={meta[k]}
              onChange={(e) => {
                const next = { ...meta, [k]: e.target.value };
                setMeta(next);
                if (manual) {
                  const entry = { ...manual, ...next };
                  writeManual(entry);
                  onChange(entry);
                }
              }}
            />
          </Field>
        ))}
      </div>
    </div>
  );
}

function DemoPanel() {
  const [i, setI] = useState(() => demoIndex());
  const cover = useMemo(() => DEMO_COVERS[i], [i]);
  return (
    <div className="space-y-3">
      <HonestNote>Demo content. These covers are generated in the app; they are not a real now-playing reading.</HonestNote>
      <div className="flex flex-wrap gap-2">
        {DEMO_COVERS.map((c, idx) => (
          <Button
            key={c.id}
            size="sm"
            variant={idx === i ? "default" : "secondary"}
            onClick={() => {
              setDemoIndex(idx);
              setI(idx);
            }}
          >
            {c.title}
          </Button>
        ))}
      </div>
      <p className="num text-[11px] text-muted-foreground">
        current: {cover.artist} — {cover.title}
      </p>
    </div>
  );
}
