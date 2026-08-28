import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { Download, RotateCcw } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import { Field, HonestNote, Strip } from "@/components/Bits";
import { NumberControl } from "@/components/NumberControl";
import { useStore, toConfigToml, DEFAULT_SETTINGS } from "@/lib/store";
import { download } from "@/lib/render";
import type { IdleBehaviour, WallSize } from "@/lib/types";

export const Route = createFileRoute("/settings")({
  head: () => ({
    meta: [
      { title: "Settings — Album Art Matrix" },
      {
        name: "description",
        content:
          "Wall size, sharpening, poll interval, brightness, idle behaviour and push-to-wall — plus a config.toml the Raspberry Pi can read.",
      },
      { property: "og:title", content: "Settings — Album Art Matrix" },
      {
        property: "og:description",
        content: "Every pipeline and wall control in one place, exportable as a Pi-ready config file.",
      },
    ],
  }),
  component: SettingsPage,
});

const IDLE: { id: IdleBehaviour; label: string; note: string }[] = [
  { id: "black", label: "Go black", note: "Panels off. Lowest power, zero light." },
  { id: "hold", label: "Hold last cover", note: "Keeps the last frame lit indefinitely." },
  { id: "dim", label: "Dim last cover", note: "Last frame at 20% brightness." },
  { id: "ambient", label: "Ambient drift", note: "A slow generated gradient so the wall is never dead." },
];

function SettingsPage() {
  const { settings, setSettings, resetSettings, gains, order, sourceConfigs, history, profiles } = useStore();
  const [confirmReset, setConfirmReset] = useState(false);

  const exportAll = () => {
    const blob = new Blob(
      [JSON.stringify({ settings, gains, order, sourceConfigs, profiles, history, exportedAt: new Date().toISOString() }, null, 2)],
      { type: "application/json" },
    );
    download(blob, "album-art-matrix-backup.json");
  };

  return (
    <div className="space-y-6">
      <header className="enter space-y-1.5">
        <p className="eyebrow">on this device, nowhere else</p>
        <h1 className="display-mid text-2xl text-foreground">Setup</h1>
        <p className="max-w-xl text-xs leading-relaxed text-muted-foreground">
          Everything is stored on this device. No account, no server-side profile.
        </p>
      </header>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Wall and pipeline</CardTitle>
        </CardHeader>
        <CardContent className="space-y-5">
          <Field label="Wall size" hint="9 panels of 64x64. 192 is the real wall; smaller sizes preview a single panel or a 2x2 slice.">
            <div className="flex gap-2">
              {([64, 128, 192] as WallSize[]).map((s) => (
                <Button
                  key={s}
                  size="sm"
                  variant={settings.wallSize === s ? "default" : "secondary"}
                  onClick={() => setSettings({ wallSize: s })}
                  className="num"
                >
                  {s}×{s}
                </Button>
              ))}
            </div>
          </Field>

          <NumberControl
            label="Unsharp radius"
            value={settings.unsharpRadius}
            min={0}
            max={3}
            step={0.1}
            unit="px"
            defaultValue={DEFAULT_SETTINGS.unsharpRadius}
            onChange={(v) => setSettings({ unsharpRadius: v })}
            hint="Gaussian radius of the unsharp mask applied after Lanczos-3 downscaling."
          />
          <NumberControl
            label="Unsharp amount"
            value={settings.unsharpPercent}
            min={0}
            max={200}
            step={5}
            unit="%"
            defaultValue={DEFAULT_SETTINGS.unsharpPercent}
            onChange={(v) => setSettings({ unsharpPercent: v })}
            hint="Downscaling to 192px softens edges; this puts the bite back without ringing."
          />
          <NumberControl
            label="Poll interval"
            value={settings.pollSeconds}
            min={2}
            max={60}
            step={1}
            unit="s"
            defaultValue={DEFAULT_SETTINGS.pollSeconds}
            onChange={(v) => setSettings({ pollSeconds: v })}
            hint="How often the source chain is asked what is playing."
          />
          <NumberControl
            label="Brightness"
            value={settings.brightness}
            min={5}
            max={100}
            step={5}
            unit="%"
            defaultValue={DEFAULT_SETTINGS.brightness}
            onChange={(v) => setSettings({ brightness: v })}
            hint="Scales the simulated emitters and the power estimate together."
          />

          <div className="flex items-center justify-between gap-4">
            <div>
              <p className="text-sm font-medium">Apply white balance</p>
              <p className="text-xs text-muted-foreground">
                Per-channel gain in linear light using the active profile ({gains.map((g) => g.toFixed(2)).join(" / ")}).
              </p>
            </div>
            <Switch checked={settings.applyWhiteBalance} onCheckedChange={(v) => setSettings({ applyWhiteBalance: v })} />
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">When nothing is playing</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-2 sm:grid-cols-2">
          {IDLE.map((o) => (
            <button
              key={o.id}
              onClick={() => setSettings({ idleBehaviour: o.id })}
              className={`rounded-lg border p-3 text-left transition-colors ${
                settings.idleBehaviour === o.id ? "border-[var(--art)]" : "border-border hover:border-foreground/30"
              }`}
            >
              <p className="display-mid text-sm text-foreground">{o.label}</p>
              <p className="mt-0.5 text-xs text-muted-foreground">{o.note}</p>
            </button>
          ))}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Push to wall</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <div className="flex items-center justify-between gap-4">
            <div>
              <p className="text-sm font-medium">Send processed frames to a Pi</p>
              <p className="text-xs text-muted-foreground">
                POSTs the exact RGB888 buffer this app renders, at the configured size.
              </p>
            </div>
            <Switch checked={settings.pushEnabled} onCheckedChange={(v) => setSettings({ pushEnabled: v })} />
          </div>
          <Field label="Format">
            <Strip
              options={[
                { id: "brain", label: "Pi brain (json)" },
                { id: "raw", label: "raw rgb888" },
              ]}
              value={settings.pushFormat}
              onChange={(v) => setSettings({ pushFormat: v })}
              size="sm"
              className="max-w-xs"
            />
          </Field>
          <Field
            label="Endpoint"
            hint={
              settings.pushFormat === "brain"
                ? "The hardware brain's control API: http://album-matrix.local:8788/frame — takes {px: base64} at 64×64 and shows it on the real wall."
                : "Any listener that accepts a bare RGB888 body as application/octet-stream, N*N*3 bytes."
            }
          >
            <Input
              className="num"
              value={settings.pushEndpoint}
              onChange={(e) => setSettings({ pushEndpoint: e.target.value })}
              placeholder={settings.pushFormat === "brain" ? "http://album-matrix.local:8788/frame" : "http://host:port/frame"}
            />
          </Field>
          <HonestNote tone="warn">
            With push on and no endpoint reachable, the app reports the failure instead of pretending the frame
            landed. The Pi brain format only accepts 64×64 frames today.
          </HonestNote>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Export</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            onClick={() =>
              download(new Blob([toConfigToml(settings, gains, order.filter((id) => sourceConfigs[id].enabled))], { type: "text/plain" }), "config.toml")
            }
          >
            <Download className="mr-2 h-4 w-4" /> config.toml
          </Button>
          <Button
            variant="secondary"
            onClick={async () => {
              await navigator.clipboard.writeText(toConfigToml(settings, gains, order.filter((id) => sourceConfigs[id].enabled)));
              toast.success("config.toml copied. Paste it straight into the hardware repo.");
            }}
          >
            copy config.toml
          </Button>
          <Button variant="secondary" onClick={exportAll}>
            <Download className="mr-2 h-4 w-4" /> Full backup (JSON)
          </Button>
          <Button
            variant={confirmReset ? "destructive" : "ghost"}
            onClick={() => {
              if (!confirmReset) return setConfirmReset(true);
              resetSettings();
              setSettings(DEFAULT_SETTINGS);
              setConfirmReset(false);
              toast.success("Settings restored to defaults.");
            }}
          >
            <RotateCcw className="mr-2 h-4 w-4" /> {confirmReset ? "Tap again to confirm" : "Reset settings"}
          </Button>
        </CardContent>
      </Card>
    </div>
  );
}
