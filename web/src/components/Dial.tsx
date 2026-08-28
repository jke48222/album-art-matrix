import { useCallback, useEffect, useRef } from "react";
import { cn } from "@/lib/utils";
import { tap } from "@/lib/haptics";

/*
 * A rotary instrument dial. 270 degree sweep, tick ring, needle, mono readout.
 * Drag vertically like a studio pot (fine control, works one-handed on a
 * phone), scroll to nudge, arrow keys when focused. SVG, flat, no gloss.
 */
export function Dial({
  value,
  min,
  max,
  step = 1,
  onChange,
  label,
  format = (v) => String(Math.round(v)),
  size = 108,
  className,
}: {
  value: number;
  min: number;
  max: number;
  step?: number;
  onChange: (v: number) => void;
  label: string;
  format?: (v: number) => string;
  size?: number;
  className?: string;
}) {
  const drag = useRef<{ startY: number; startV: number } | null>(null);
  const lastTapped = useRef(value);

  const clamp = useCallback(
    (v: number) => Math.min(max, Math.max(min, Math.round(v / step) * step)),
    [min, max, step],
  );

  const set = useCallback(
    (v: number) => {
      const c = clamp(v);
      if (c !== value) {
        // A soft click every 5% of travel, like detents.
        if (Math.abs(c - lastTapped.current) >= (max - min) * 0.05) {
          tap();
          lastTapped.current = c;
        }
        onChange(c);
      }
    },
    [clamp, onChange, value, min, max],
  );

  const onPointerDown = (e: React.PointerEvent) => {
    (e.target as Element).setPointerCapture(e.pointerId);
    drag.current = { startY: e.clientY, startV: value };
  };
  const onPointerMove = (e: React.PointerEvent) => {
    if (!drag.current) return;
    const dy = drag.current.startY - e.clientY;
    // Full travel over ~180 px of drag; shift for fine.
    const range = max - min;
    const scale = e.shiftKey ? 720 : 180;
    set(drag.current.startV + (dy / scale) * range);
  };
  const onPointerUp = () => {
    drag.current = null;
  };

  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      set(value + (e.deltaY < 0 ? step : -step) * (e.shiftKey ? 1 : Math.max(1, (max - min) / 50)));
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [value, step, min, max, set]);

  const frac = (value - min) / (max - min);
  const START = -225; // degrees
  const SWEEP = 270;
  const angle = START + frac * SWEEP;
  const r = size / 2;
  const tickR0 = r - 4;
  const tickR1 = r - 10;
  const needleR = r - 16;
  const cx = r;
  const cy = r;

  const ticks = [];
  const N = 27;
  for (let i = 0; i <= N; i++) {
    const a = ((START + (i / N) * SWEEP) * Math.PI) / 180;
    const on = i / N <= frac + 1e-6;
    const major = i % 9 === 0;
    ticks.push(
      <line
        key={i}
        x1={+(cx + Math.cos(a) * (major ? tickR0 + 2 : tickR0)).toFixed(2)}
        y1={+(cy + Math.sin(a) * (major ? tickR0 + 2 : tickR0)).toFixed(2)}
        x2={+(cx + Math.cos(a) * tickR1).toFixed(2)}
        y2={+(cy + Math.sin(a) * tickR1).toFixed(2)}
        stroke={on ? "var(--art)" : "var(--border)"}
        strokeWidth={major ? 2 : 1}
      />,
    );
  }

  const na = (angle * Math.PI) / 180;

  return (
    <div className={cn("flex flex-col items-center gap-1.5", className)}>
      <div
        ref={ref}
        role="slider"
        aria-label={label}
        aria-valuemin={min}
        aria-valuemax={max}
        aria-valuenow={value}
        tabIndex={0}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onKeyDown={(e) => {
          const big = Math.max(step, (max - min) / 20);
          if (e.key === "ArrowUp" || e.key === "ArrowRight") set(value + big);
          if (e.key === "ArrowDown" || e.key === "ArrowLeft") set(value - big);
          if (e.key === "Home") set(min);
          if (e.key === "End") set(max);
        }}
        className="press relative cursor-ns-resize touch-none select-none rounded-full"
        style={{ width: size, height: size }}
      >
        <svg width={size} height={size} aria-hidden>
          <circle cx={cx} cy={cy} r={needleR + 3} fill="var(--surface-sunk)" stroke="var(--border)" />
          {ticks}
          {/* needle */}
          <line
            x1={+(cx + Math.cos(na) * (needleR - 14)).toFixed(2)}
            y1={+(cy + Math.sin(na) * (needleR - 14)).toFixed(2)}
            x2={+(cx + Math.cos(na) * needleR).toFixed(2)}
            y2={+(cy + Math.sin(na) * needleR).toFixed(2)}
            stroke="var(--foreground)"
            strokeWidth={2.5}
            strokeLinecap="round"
          />
        </svg>
        <div className="pointer-events-none absolute inset-0 grid place-items-center">
          <span className="num text-sm text-foreground">{format(value)}</span>
        </div>
      </div>
      <span className="eyebrow">{label}</span>
    </div>
  );
}
