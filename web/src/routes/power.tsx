import { createFileRoute } from "@tanstack/react-router";
import { useMemo, useState } from "react";
import { Input } from "@/components/ui/input";
import { Field, HonestNote, Readout } from "@/components/Bits";
import { computePower, DEFAULT_POWER, type PowerInputs, type PowerOutputs } from "@/lib/power";

export const Route = createFileRoute("/power")({
  head: () => ({
    meta: [
      { title: "Power calculator - Album Art Matrix" },
      {
        name: "description",
        content:
          "Circuit model for a HUB75 LED wall: trunk IR drop, voltage at the panel and the supply trim needed to land 5.00 V.",
      },
      { property: "og:title", content: "Power calculator - Album Art Matrix" },
      {
        property: "og:description",
        content: "Model trunk IR drop, panel voltage and supply trim for a 3x3 HUB75 P2.5 LED wall.",
      },
    ],
  }),
  component: PowerPage,
});

/*
 * The feed, drawn as the circuit it is: PSU → trunk → fuse → harness → panel,
 * with the voltage falling left to right. Wire weight follows gauge; the
 * panel node goes signal red when it lands below 4.9 V.
 */
function FeedDiagram({ i, o }: { i: PowerInputs; o: PowerOutputs }) {
  const W = 640;
  const H = 170;
  const railY = 62;
  const psu = { x: 8, w: 92 };
  const panel = { x: W - 100, w: 92 };
  const wireX0 = psu.x + psu.w;
  const wireX1 = panel.x;
  const span = wireX1 - wireX0;
  // Segment widths proportional to their share of the drop (min widths keep labels readable).
  const drops = [o.trunkDrop, o.fuseDrop, o.harnessDrop];
  const total = Math.max(1e-9, drops.reduce((a, b) => a + b, 0));
  const minW = 70;
  const flex = span - minW * 3 - 26 * 2;
  const seg = drops.map((d) => minW + Math.max(0, flex) * (d / total));

  const trunkW = i.trunkAwg === 14 ? 5 : 3;
  const ok = !o.warning;
  const panelColor = ok ? "var(--success)" : "var(--primary)";

  // Voltage profile under the rail: supply → after trunk → after fuse → panel.
  const vs = [i.supplyVolts, i.supplyVolts - o.trunkDrop, i.supplyVolts - o.trunkDrop - o.fuseDrop, o.panelVolts];
  const vMin = Math.min(...vs, 4.8);
  const vMax = Math.max(...vs, 5.05);
  const profY = (v: number) => H - 8 - ((v - vMin) / (vMax - vMin)) * 34;
  const profXs = [wireX0, wireX0 + seg[0], wireX0 + seg[0] + 26 + seg[1], wireX1];

  let x = wireX0;
  const segments: { x0: number; x1: number; label: string; drop: number; stroke: number }[] = [];
  segments.push({ x0: x, x1: (x += seg[0]), label: `trunk ${i.trunkLengthM.toFixed(1)} m / ${i.trunkAwg} awg`, drop: o.trunkDrop, stroke: trunkW });
  const fuseX = x + 4;
  x += 26;
  segments.push({ x0: x, x1: (x += seg[1]), label: "fuse + clip", drop: o.fuseDrop, stroke: trunkW });
  const jX = x + 4;
  x += 26;
  segments.push({ x0: x, x1: wireX1, label: `harness ${i.harnessLengthM.toFixed(1)} m / 18 awg`, drop: o.harnessDrop, stroke: 2 });

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="w-full">
      {/* PSU node */}
      <rect x={psu.x} y={railY - 26} width={psu.w} height={52} fill="var(--surface-sunk)" stroke="var(--border)" />
      <text x={psu.x + psu.w / 2} y={railY - 8} textAnchor="middle" fill="var(--muted-foreground)" style={{ font: "9px var(--font-mono)", letterSpacing: "0.1em" }}>
        PSU TRIM
      </text>
      <text x={psu.x + psu.w / 2} y={railY + 12} textAnchor="middle" fill="var(--foreground)" style={{ font: "15px var(--font-mono)" }}>
        {i.supplyVolts.toFixed(2)} V
      </text>

      {/* wire segments */}
      {segments.map((s, idx) => (
        <g key={idx}>
          <line x1={s.x0} y1={railY} x2={s.x1} y2={railY} stroke="var(--art)" strokeWidth={s.stroke} opacity={0.9 - idx * 0.15} />
          <text x={(s.x0 + s.x1) / 2} y={railY - 12} textAnchor="middle" fill="var(--muted-foreground)" style={{ font: "8.5px var(--font-mono)", letterSpacing: "0.06em" }}>
            {s.label}
          </text>
          <text x={(s.x0 + s.x1) / 2} y={railY + 18} textAnchor="middle" fill={s.drop > 0.15 ? "var(--warning)" : "var(--muted-foreground)"} style={{ font: "9px var(--font-mono)" }}>
            −{s.drop.toFixed(3)} V
          </text>
        </g>
      ))}

      {/* fuse symbol */}
      <rect x={fuseX} y={railY - 6} width={18} height={12} fill="none" stroke="var(--art)" strokeWidth={1.5} />
      <line x1={fuseX} y1={railY} x2={fuseX + 18} y2={railY} stroke="var(--art)" strokeWidth={1} />
      {/* junction dot */}
      <circle cx={jX + 9} cy={railY} r={2.5} fill="var(--art)" />

      {/* Panel node */}
      <rect x={panel.x} y={railY - 26} width={panel.w} height={52} fill="var(--surface-sunk)" stroke={panelColor} strokeWidth={1.5} />
      <text x={panel.x + panel.w / 2} y={railY - 8} textAnchor="middle" fill="var(--muted-foreground)" style={{ font: "9px var(--font-mono)", letterSpacing: "0.1em" }}>
        AT THE PANEL
      </text>
      <text x={panel.x + panel.w / 2} y={railY + 12} textAnchor="middle" fill={panelColor} style={{ font: "15px var(--font-mono)" }}>
        {o.panelVolts.toFixed(2)} V
      </text>

      {/* voltage profile */}
      <text x={wireX0} y={H - 48} fill="var(--muted-foreground)" style={{ font: "8px var(--font-mono)", letterSpacing: "0.1em" }}>
        VOLTAGE ALONG THE RUN
      </text>
      <line x1={wireX0} y1={profY(4.9)} x2={wireX1} y2={profY(4.9)} stroke="var(--primary)" strokeDasharray="3 4" opacity={0.55} />
      <text x={wireX1 + 4} y={profY(4.9) + 3} fill="var(--primary)" style={{ font: "8px var(--font-mono)" }}>
        4.90
      </text>
      <polyline
        points={profXs.map((px, k) => `${px},${profY(vs[k])}`).join(" ")}
        fill="none"
        stroke="var(--foreground)"
        strokeWidth={1.5}
      />
      {profXs.map((px, k) => (
        <circle key={k} cx={px} cy={profY(vs[k])} r={2} fill="var(--foreground)" />
      ))}
    </svg>
  );
}

function PowerPage() {
  const [inputs, setInputs] = useState<PowerInputs>(DEFAULT_POWER);
  const out = useMemo(() => computePower(inputs), [inputs]);
  const set = (patch: Partial<PowerInputs>) => setInputs((p) => ({ ...p, ...patch }));

  return (
    <div className="space-y-6">
      <header className="enter space-y-1.5">
        <p className="eyebrow">a circuit model, not a measurement</p>
        <h1 className="display-mid text-2xl text-foreground">Power</h1>
        <p className="max-w-xl text-xs leading-relaxed text-muted-foreground">
          Planning tool for the wiring: what each section of the feed costs in volts, and where the supply has to sit
          so 5.00 V actually arrives at the panel.
        </p>
      </header>

      <div className="placard enter-1 p-4">
        <FeedDiagram i={inputs} o={out} />
        {out.warning && (
          <p className="num mt-2 border-t border-primary/40 pt-2.5 text-[10px] leading-relaxed text-primary">
            {out.panelVolts.toFixed(2)} V at the panel is below 4.90 V. The driver chips misbehave under that: dim
            patches, colour shifts, flicker on bright frames - which looks exactly like a software bug. Shorten the
            trunk, go heavier, split the feed, or trim the supply up.
          </p>
        )}
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <div className="placard space-y-4 p-5">
          <p className="eyebrow">inputs</p>
          <div className="grid gap-3.5 sm:grid-cols-2">
            <Field label="panels">
              <Input
                type="number"
                value={inputs.panels}
                min={1}
                onChange={(e) => set({ panels: Math.max(1, Number(e.target.value) || 1) })}
              />
            </Field>
            <Field label="panels per feed section">
              <Input
                type="number"
                value={inputs.panelsPerSection}
                min={1}
                onChange={(e) => set({ panelsPerSection: Math.max(1, Number(e.target.value) || 1) })}
              />
            </Field>
            <Field label="amps per panel, full white">
              <Input
                type="number"
                step="0.1"
                value={inputs.ampsPerPanel}
                onChange={(e) => set({ ampsPerPanel: Number(e.target.value) || 0 })}
              />
            </Field>
            <Field label="trunk length (m)">
              <Input
                type="number"
                step="0.1"
                value={inputs.trunkLengthM}
                onChange={(e) => set({ trunkLengthM: Number(e.target.value) || 0 })}
              />
            </Field>
            <Field label="trunk gauge">
              <select
                className="num h-9 w-full rounded-md border border-border bg-surface-sunk px-3 text-xs text-foreground outline-none"
                value={inputs.trunkAwg}
                onChange={(e) => set({ trunkAwg: Number(e.target.value) as 14 | 18 })}
              >
                <option value={14}>14 AWG</option>
                <option value={18}>18 AWG</option>
              </select>
            </Field>
            <Field label="fuse + clip (mΩ)">
              <Input
                type="number"
                step="0.5"
                value={inputs.fuseClipMilliOhm}
                onChange={(e) => set({ fuseClipMilliOhm: Number(e.target.value) || 0 })}
              />
            </Field>
            <Field label="harness per panel (m, 18 awg)">
              <Input
                type="number"
                step="0.1"
                value={inputs.harnessLengthM}
                onChange={(e) => set({ harnessLengthM: Number(e.target.value) || 0 })}
              />
            </Field>
            <Field label="supply trim (V)">
              <Input
                type="number"
                step="0.05"
                value={inputs.supplyVolts}
                onChange={(e) => set({ supplyVolts: Number(e.target.value) || 0 })}
              />
            </Field>
          </div>
        </div>

        <div className="space-y-4">
          <div className="placard p-5">
            <p className="eyebrow mb-2">modelled results</p>
            <Readout label="total current" value={`${out.totalAmps.toFixed(1)} A`} />
            <Readout label="feed sections" value={`${out.sections}`} />
            <Readout label="current per section" value={`${out.sectionAmps.toFixed(1)} A`} />
            <Readout label="trunk resistance, out + back" value={`${(out.trunkOhms * 1000).toFixed(1)} mΩ`} />
            <Readout label="drop / trunk" value={`${out.trunkDrop.toFixed(3)} V`} />
            <Readout label="drop / fuse and clip" value={`${out.fuseDrop.toFixed(3)} V`} />
            <Readout label="drop / harness" value={`${out.harnessDrop.toFixed(3)} V`} />
            <Readout label="total drop" value={`${out.totalDrop.toFixed(3)} V`} />
            <Readout label="voltage at the panel" value={`${out.panelVolts.toFixed(2)} V`} tone={out.warning ? "alert" : undefined} />
            <Readout label="trim to land 5.00 v" value={`${out.requiredTrim.toFixed(2)} V`} />
          </div>

          <div className="placard p-5">
            <p className="eyebrow mb-2">reference figures</p>
            <p className="num text-[11px] leading-relaxed text-muted-foreground">
              1.0 m of 14 AWG trunk → 4.71 V at the panel from a 5.00 V supply, ~5.30 V trim.
              <br />
              0.5 m of 14 AWG trunk → 4.81 V at the panel, ~5.20 V trim.
            </p>
          </div>

          <HonestNote>
            Resistances are copper at 20 C (14 AWG 8.286 mΩ/m, 18 AWG 20.95 mΩ/m per conductor). Real connectors,
            crimps and hot copper all add drop. Treat these numbers as a model to plan with, then measure at the panel.
          </HonestNote>
        </div>
      </div>
    </div>
  );
}
