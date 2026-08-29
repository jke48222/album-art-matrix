import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { Check, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Field, GuessBadge, HonestNote, MeasuredBadge } from "@/components/Bits";
import { BUILTIN_PROFILE, DEFAULT_GAINS, useStore } from "@/lib/store";
import type { WbProfile } from "@/lib/types";

export const Route = createFileRoute("/profiles")({
  head: () => ({
    meta: [
      { title: "White balance profiles - Album Art Matrix" },
      {
        name: "description",
        content:
          "Named, measurable white balance profiles for RGB LED panels, with a measurement procedure and honest guess badges.",
      },
      { property: "og:title", content: "White balance profiles - Album Art Matrix" },
      {
        property: "og:description",
        content: "Save measured LED panel white balance profiles, or keep the published typical values badged as a guess.",
      },
    ],
  }),
  component: ProfilesPage,
});

function ProfilesPage() {
  const { profiles, activeProfile, setActiveProfile, addProfile, deleteProfile } = useStore();
  const [name, setName] = useState("");
  const [notes, setNotes] = useState("");
  const [mode, setMode] = useState<"rgb" | "xyz">("rgb");
  const [m, setM] = useState({ a: 255, b: 240, c: 210 });

  // Corrective gains: invert the reading, then normalise so the largest gain is 1.00.
  const inv = [1 / Math.max(m.a, 1e-6), 1 / Math.max(m.b, 1e-6), 1 / Math.max(m.c, 1e-6)];
  const maxInv = Math.max(...inv);
  const computed = inv.map((v) => Number((v / maxInv).toFixed(2))) as [number, number, number];

  const saveMeasured = () => {
    if (!name.trim()) {
      toast.error("Give the profile a name.");
      return;
    }
    const p: WbProfile = {
      id: crypto.randomUUID(),
      name: name.trim(),
      gainR: computed[0],
      gainG: computed[1],
      gainB: computed[2],
      isMeasured: true,
      notes: `${mode.toUpperCase()} reading ${m.a} / ${m.b} / ${m.c}. ${notes}`.trim(),
      createdAt: new Date().toISOString(),
    };
    addProfile(p);
    setActiveProfile(p.id);
    setName("");
    setNotes("");
    toast.success(`Saved measured profile “${p.name}” and made it active.`);
  };

  return (
    <div className="space-y-6">
      <header className="enter space-y-1.5">
        <p className="eyebrow">colour, owned honestly</p>
        <h1 className="display-mid text-2xl text-foreground">Balance</h1>
        <p className="max-w-xl text-xs leading-relaxed text-muted-foreground">
          RGB LED panels are not neutral: green and blue emitters are far more efficient than red, so an uncorrected
          white frame comes out cyan. Gains are applied in linear light, after gamma decode.
        </p>
      </header>

      <HonestNote tone="warn">
        The default gains (R 1.00 / G 0.75 / B 0.55) are published typical values, <strong>not a measurement of any
        panel</strong>. They stay badged as a guess until you enter a reading.
      </HonestNote>

      <div className="grid gap-6 lg:grid-cols-[1.1fr_1fr]">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Profiles</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {profiles.map((p) => {
              const active = p.id === activeProfile.id;
              const delta: [number, number, number] = [
                p.gainR - DEFAULT_GAINS[0],
                p.gainG - DEFAULT_GAINS[1],
                p.gainB - DEFAULT_GAINS[2],
              ];
              return (
                <div
                  key={p.id}
                  className={`rounded-lg border p-3.5 ${active ? "border-[var(--art)]" : "border-border"}`}
                >
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="display-mid text-sm text-foreground">{p.name}</span>
                    {p.isMeasured ? <MeasuredBadge /> : <GuessBadge />}
                    <span className="num ml-auto text-xs text-muted-foreground">
                      R {p.gainR.toFixed(2)} / G {p.gainG.toFixed(2)} / B {p.gainB.toFixed(2)}
                    </span>
                  </div>
                  <GainBars r={p.gainR} g={p.gainG} b={p.gainB} />
                  <p className="mt-2 text-xs leading-relaxed text-muted-foreground">{p.notes}</p>
                  <p className="num mt-1.5 text-[11px] text-muted-foreground">
                    Δ vs defaults: R {delta[0] >= 0 ? "+" : ""}
                    {delta[0].toFixed(2)} / G {delta[1] >= 0 ? "+" : ""}
                    {delta[1].toFixed(2)} / B {delta[2] >= 0 ? "+" : ""}
                    {/* ISO date, not toLocaleDateString: this renders during
                        SSR, and a locale/timezone-dependent string hydrates
                        differently on the client */}
                    {delta[2].toFixed(2)}, created {String(p.createdAt).slice(0, 10)}
                  </p>
                  <div className="mt-3 flex gap-2">
                    <Button size="sm" variant={active ? "secondary" : "default"} onClick={() => setActiveProfile(p.id)}>
                      {active ? (
                        <>
                          <Check className="mr-1 h-3.5 w-3.5" /> Active
                        </>
                      ) : (
                        "Use this profile"
                      )}
                    </Button>
                    {p.id !== BUILTIN_PROFILE.id && (
                      <Button size="sm" variant="ghost" onClick={() => deleteProfile(p.id)}>
                        <Trash2 className="h-3.5 w-3.5" />
                      </Button>
                    )}
                  </div>
                </div>
              );
            })}
          </CardContent>
        </Card>

        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Enter a measurement</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="flex gap-2">
                {(["rgb", "xyz"] as const).map((v) => (
                  <Button key={v} size="sm" variant={mode === v ? "default" : "secondary"} onClick={() => setMode(v)}>
                    {v.toUpperCase()}
                  </Button>
                ))}
              </div>
              <div className="grid grid-cols-3 gap-3">
                {(mode === "rgb" ? ["R", "G", "B"] : ["X", "Y", "Z"]).map((l, i) => (
                  <Field key={l} label={l}>
                    <Input
                      type="number"
                      className="num"
                      step="0.01"
                      value={[m.a, m.b, m.c][i]}
                      onChange={(e) => {
                        const v = Number(e.target.value) || 0;
                        setM((p) => ({ ...p, [["a", "b", "c"][i] as "a"]: v }));
                      }}
                    />
                  </Field>
                ))}
              </div>
              <div className="placard-sunk p-3.5">
                <p className="eyebrow">corrective gains / largest normalised to 1.00</p>
                <p className="num mt-1.5 text-sm text-[var(--art)]">
                  R {computed[0].toFixed(2)} / G {computed[1].toFixed(2)} / B {computed[2].toFixed(2)}
                </p>
                <GainBars r={computed[0]} g={computed[1]} b={computed[2]} />
              </div>
              <Field label="Profile name">
                <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="Panel batch A, sensor X100" />
              </Field>
              <Field label="Notes">
                <Textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} placeholder="Sensor, distance, ambient conditions" />
              </Field>
              <Button onClick={saveMeasured}>Save as measured profile</Button>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Measurement procedure</CardTitle>
            </CardHeader>
            <CardContent>
              <ol className="list-decimal space-y-1.5 pl-5 text-xs leading-relaxed text-muted-foreground marker:font-mono marker:text-[10px] marker:text-muted-foreground/60">
                <li>Set the wall to the full white test pattern at 100% brightness.</li>
                <li>
                  <strong className="text-foreground">Warm the panel up for ten minutes.</strong> LED output shifts as
                  the panel heats; a cold reading is the wrong reading.
                </li>
                <li>Kill ambient light, or at least keep it constant and off-axis.</li>
                <li>Hold the colour sensor square to the panel, a fixed distance away, and let it settle.</li>
                <li>Record the R/G/B (or XYZ) reading and enter it above.</li>
                <li>Apply the resulting profile, show full white again, and confirm the reading is now neutral.</li>
              </ol>
            </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}

/* The three gains as instrument bars, in the emitters' own colours. */
function GainBars({ r, g, b }: { r: number; g: number; b: number }) {
  const rows: { c: string; v: number }[] = [
    { c: "rgb(228 88 64)", v: r },
    { c: "rgb(96 200 120)", v: g },
    { c: "rgb(92 140 236)", v: b },
  ];
  return (
    <div className="mt-2.5 space-y-1">
      {rows.map(({ c, v }, i) => (
        <div key={i} className="flex items-center gap-2">
          <span className="h-px flex-1 bg-border">
            <span className="block h-[3px] -translate-y-px" style={{ width: `${Math.min(1, v / 2) * 100}%`, background: c, opacity: 0.85 }} />
          </span>
          <span className="num w-10 text-right text-[9px] text-muted-foreground">{v.toFixed(2)}</span>
        </div>
      ))}
    </div>
  );
}
