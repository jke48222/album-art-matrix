import { RotateCcw } from "lucide-react";
import { Slider } from "@/components/ui/slider";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";

export function NumberControl({
  label,
  value,
  min,
  max,
  step,
  onChange,
  defaultValue,
  unit,
  hint,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (v: number) => void;
  defaultValue: number;
  unit?: string;
  hint?: string;
}) {
  const decimals = step < 1 ? String(step).split(".")[1]?.length ?? 2 : 0;
  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between gap-2">
        <span className="eyebrow">{label}</span>
        <div className="flex items-center gap-1">
          <Input
            type="number"
            className="num h-8 w-20 text-right text-xs"
            value={Number(value).toFixed(decimals)}
            min={min}
            max={max}
            step={step}
            onChange={(e) => {
              const v = Number(e.target.value);
              if (!Number.isNaN(v)) onChange(Math.min(max, Math.max(min, v)));
            }}
          />
          {unit && <span className="num w-6 text-[11px] text-muted-foreground">{unit}</span>}
          <Button
            variant="ghost"
            size="icon"
            className="h-8 w-8 shrink-0"
            title={`Reset to ${defaultValue}`}
            onClick={() => onChange(defaultValue)}
          >
            <RotateCcw className="h-3.5 w-3.5" />
          </Button>
        </div>
      </div>
      <Slider
        value={[value]}
        min={min}
        max={max}
        step={step}
        onValueChange={([v]) => onChange(v)}
        className="py-1"
      />
      {hint && <p className="text-[11px] leading-relaxed text-muted-foreground">{hint}</p>}
    </div>
  );
}
