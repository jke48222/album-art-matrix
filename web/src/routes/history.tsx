import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMemo, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { HonestNote, SectionTitle } from "@/components/Bits";
import { useStore } from "@/lib/store";
import { download } from "@/lib/render";
import { tap } from "@/lib/haptics";
import type { HistoryEntry, SourceId } from "@/lib/types";

export const Route = createFileRoute("/history")({
  head: () => ({
    meta: [
      { title: "Play history — Album Art Matrix" },
      {
        name: "description",
        content:
          "Every track the wall has shown: searchable, grouped by day, with the source that answered and the settings it was rendered with.",
      },
      { property: "og:title", content: "Play history — Album Art Matrix" },
      {
        property: "og:description",
        content: "Browse, filter, re-render and export everything the LED wall has displayed.",
      },
    ],
  }),
  component: HistoryPage,
});

function toCsv(rows: HistoryEntry[]) {
  const head = ["played_at", "title", "artist", "album", "source", "source_tier", "duration_ms", "art_url"];
  const esc = (v: unknown) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  return [
    head.join(","),
    ...rows.map((r) =>
      [new Date(r.playedAt).toISOString(), r.title, r.artist, r.album, r.source, r.sourceTier, r.durationMs, r.artUrl]
        .map(esc)
        .join(","),
    ),
  ].join("\n");
}

/* Fourteen days of activity as a flat bar chart. Real counts, no smoothing. */
function ActivityChart({ history }: { history: HistoryEntry[] }) {
  const days = useMemo(() => {
    const out: { key: string; label: string; n: number }[] = [];
    const today = new Date();
    for (let i = 13; i >= 0; i--) {
      const d = new Date(today);
      d.setDate(today.getDate() - i);
      out.push({
        key: d.toDateString(),
        label: d.toLocaleDateString(undefined, { weekday: "narrow" }),
        n: 0,
      });
    }
    const idx = new Map(out.map((d, i) => [d.key, i]));
    for (const e of history) {
      const i = idx.get(new Date(e.playedAt).toDateString());
      if (i != null) out[i].n++;
    }
    return out;
  }, [history]);

  const max = Math.max(1, ...days.map((d) => d.n));
  const W = 560;
  const H = 96;
  const bw = W / days.length;

  return (
    <div className="placard p-4">
      <div className="flex items-baseline justify-between">
        <p className="eyebrow">fourteen days</p>
        <p className="num text-[10px] text-muted-foreground">peak {max === 1 && days.every((d) => d.n <= 1) ? days.reduce((a, d) => Math.max(a, d.n), 0) : max} / day</p>
      </div>
      <svg viewBox={`0 0 ${W} ${H + 16}`} className="mt-2 w-full">
        <line x1="0" y1={H} x2={W} y2={H} stroke="var(--border)" />
        {days.map((d, i) => {
          const h = d.n === 0 ? 0 : Math.max(3, (d.n / max) * (H - 12));
          return (
            <g key={d.key}>
              {d.n > 0 && (
                <rect
                  x={i * bw + bw * 0.3}
                  y={H - h}
                  width={bw * 0.4}
                  height={h}
                  fill="var(--art)"
                  opacity={0.4 + 0.6 * (d.n / max)}
                />
              )}
              <text
                x={i * bw + bw / 2}
                y={H + 12}
                textAnchor="middle"
                fill="var(--muted-foreground)"
                style={{ font: "8px var(--font-mono)", opacity: 0.7 }}
              >
                {d.label}
              </text>
            </g>
          );
        })}
      </svg>
    </div>
  );
}

function HistoryPage() {
  const { history, deleteHistory, clearHistory, setSettings } = useStore();
  const [q, setQ] = useState("");
  const [source, setSource] = useState<"all" | SourceId>("all");
  const navigate = useNavigate();

  const filtered = useMemo(
    () =>
      history.filter(
        (e) =>
          (source === "all" || e.source === source) &&
          (q.trim() === "" || `${e.title} ${e.artist} ${e.album}`.toLowerCase().includes(q.trim().toLowerCase())),
      ),
    [history, q, source],
  );

  const byDay = useMemo(() => {
    const groups = new Map<string, HistoryEntry[]>();
    for (const e of filtered) {
      const key = new Date(e.playedAt).toDateString();
      groups.set(key, [...(groups.get(key) ?? []), e]);
    }
    return [...groups.entries()];
  }, [filtered]);

  const stats = useMemo(() => {
    const count = <T extends string>(vals: T[]) => {
      const m = new Map<T, number>();
      vals.forEach((v) => m.set(v, (m.get(v) ?? 0) + 1));
      return [...m.entries()].sort((a, b) => b[1] - a[1]);
    };
    return {
      artists: count(history.map((h) => h.artist)).slice(0, 6),
      albums: count(history.map((h) => h.album || "–")).slice(0, 6),
      sources: count(history.map((h) => h.source)),
    };
  }, [history]);

  return (
    <div className="space-y-6">
      <header className="enter flex flex-wrap items-end justify-between gap-3">
        <div className="min-w-0 space-y-1.5">
          <p className="eyebrow">what the wall has worn</p>
          <h1 className="display-mid text-2xl text-foreground">History</h1>
          <p className="max-w-xl text-xs leading-relaxed text-muted-foreground">
            Every track that played, with the source and tier that answered and the settings it was rendered with. The
            hardware brain records nothing; this is where that gets fixed.
          </p>
        </div>
        <div className="flex flex-wrap gap-1.5">
          <Button
            variant="secondary"
            size="sm"
            onClick={() =>
              download(
                new Blob([JSON.stringify(history, null, 2)], { type: "application/json" }),
                "album-art-matrix-history.json",
              )
            }
          >
            json
          </Button>
          <Button
            variant="secondary"
            size="sm"
            onClick={() => download(new Blob([toCsv(history)], { type: "text/csv" }), "album-art-matrix-history.csv")}
          >
            csv
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              if (window.confirm("Clear the entire history? This cannot be undone.")) clearHistory();
            }}
          >
            clear all
          </Button>
        </div>
      </header>

      {history.length > 0 && <ActivityChart history={history} />}

      <div className="flex flex-wrap gap-1.5">
        <Input
          className="max-w-xs"
          placeholder="Search title, artist, album"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
        <select
          className="num h-9 rounded-md border border-border bg-transparent px-3 text-[10px] uppercase tracking-[0.08em] text-muted-foreground outline-none"
          value={source}
          onChange={(e) => setSource(e.target.value as never)}
        >
          <option value="all">all sources</option>
          {["applemusic", "spotify", "acoustid", "lastfm", "mpris", "manual", "demo"].map((s) => (
            <option key={s} value={s}>
              {s}
            </option>
          ))}
        </select>
      </div>

      {history.length === 0 ? (
        <HonestNote>
          Nothing recorded yet. Every track that reaches the wall gets logged here — title, artist, album, art, the
          source and tier that answered, and the settings active when it was rendered.
        </HonestNote>
      ) : (
        <div className="grid gap-6 lg:grid-cols-[1.6fr_1fr]">
          <div className="space-y-6">
            {byDay.map(([day, entries]) => (
              <section key={day} className="space-y-2">
                <div className="flex items-baseline gap-3">
                  <h2 className="eyebrow shrink-0">{day}</h2>
                  <span className="hairline-b h-px flex-1 self-center" />
                  <span className="num text-[10px] text-muted-foreground">{entries.length}</span>
                </div>
                <div className="space-y-1.5">
                  {entries.map((e) => (
                    <div key={e.id} className="placard group flex items-center gap-3 p-2.5">
                      <div className="h-12 w-12 shrink-0 overflow-hidden bg-black">
                        {e.thumb && (
                          <img
                            src={e.thumb}
                            alt=""
                            className="h-full w-full object-cover"
                            style={{ imageRendering: "pixelated" }}
                          />
                        )}
                      </div>
                      <div className="min-w-0 flex-1">
                        <p className="display-mid truncate text-sm text-foreground">{e.title}</p>
                        <p className="num truncate text-[11px] text-muted-foreground">
                          {e.artist}
                          {e.album ? ` — ${e.album}` : ""}
                        </p>
                        <p className="num mt-0.5 truncate text-[9px] uppercase tracking-[0.08em] text-muted-foreground/70">
                          {new Date(e.playedAt).toLocaleTimeString()} · {e.source}
                          {e.sourceTier ? ` · ${e.sourceTier}` : ""} · {e.settingsSnapshot.wallSize}px · r
                          {e.settingsSnapshot.gainR.toFixed(2)} g{e.settingsSnapshot.gainG.toFixed(2)} b
                          {e.settingsSnapshot.gainB.toFixed(2)}
                        </p>
                      </div>
                      <div className="flex shrink-0 flex-col items-end gap-1">
                        <button
                          className="num press text-[9px] uppercase tracking-[0.12em] text-muted-foreground hover:text-foreground"
                          onClick={() => {
                            tap();
                            sessionStorage.setItem(
                              "aam.rerender",
                              JSON.stringify({
                                artUrl: e.artUrl,
                                title: e.title,
                                artist: e.artist,
                                album: e.album,
                                trackId: e.trackId,
                              }),
                            );
                            void navigate({ to: "/" });
                          }}
                        >
                          re-render
                        </button>
                        <button
                          className="num press text-[9px] uppercase tracking-[0.12em] text-muted-foreground hover:text-foreground"
                          onClick={() => {
                            tap();
                            const { gainR, gainG, gainB, ...s } = e.settingsSnapshot;
                            void gainR;
                            void gainG;
                            void gainB;
                            setSettings(s);
                            toast.success("Restored the settings this track was rendered with.");
                          }}
                        >
                          restore settings
                        </button>
                        <button
                          className="num press text-[9px] uppercase tracking-[0.12em] text-muted-foreground/60 hover:text-primary"
                          onClick={() => {
                            tap();
                            deleteHistory(e.id);
                          }}
                        >
                          delete
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              </section>
            ))}
          </div>

          <div className="space-y-4">
            <div className="placard space-y-5 p-5">
              <SectionTitle eyebrow="counted, not estimated" title="Stats" />
              <StatList title="most-played artists" rows={stats.artists} />
              <StatList title="most-played albums" rows={stats.albums} />
              <StatList title="which source answered" rows={stats.sources} />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function StatList({ title, rows }: { title: string; rows: [string, number][] }) {
  const max = Math.max(1, ...rows.map((r) => r[1]));
  return (
    <div className="space-y-2">
      <p className="eyebrow">{title}</p>
      {rows.length === 0 && <p className="num text-[10px] text-muted-foreground">nothing yet</p>}
      {rows.map(([k, v]) => (
        <div key={k} className="space-y-1">
          <div className="flex justify-between gap-2">
            <span className="num truncate text-[11px] text-muted-foreground">{k}</span>
            <span className="num text-[11px] text-foreground">{v}</span>
          </div>
          <div className="h-px bg-border">
            <div className="-mt-px h-[3px] bg-[var(--art)]" style={{ width: `${(v / max) * 100}%` }} />
          </div>
        </div>
      ))}
    </div>
  );
}
