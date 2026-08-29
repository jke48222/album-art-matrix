import { useLayoutEffect, useRef, useState } from "react";
import { cn } from "@/lib/utils";
import { tap } from "@/lib/haptics";
import type { SourceState } from "@/lib/types";

/* ---------- status language ---------- */

const STATE_META: Record<SourceState, { label: string; dot: string; text: string }> = {
  connected: { label: "connected", dot: "bg-success", text: "text-success" },
  disconnected: { label: "disconnected", dot: "bg-muted-foreground/50", text: "text-muted-foreground" },
  "needs-setup": { label: "needs setup", dot: "bg-warning", text: "text-warning" },
  "needs-bridge": { label: "needs bridge", dot: "bg-muted-foreground/50", text: "text-muted-foreground" },
  error: { label: "error", dot: "bg-primary", text: "text-primary" },
  "no-answer": { label: "no answer", dot: "bg-muted-foreground/50", text: "text-muted-foreground" },
};

export function StateBadge({ state, live }: { state: SourceState; live?: boolean }) {
  const s = STATE_META[state];
  return (
    <span className={cn("num inline-flex items-center gap-1.5 text-[10px] uppercase tracking-[0.1em]", s.text)}>
      <span className={cn("h-[5px] w-[5px] rounded-full", s.dot, live && "pulse-dot")} />
      {s.label}
    </span>
  );
}

/* ---------- placard furniture ---------- */

export function HonestNote({ children, tone = "default" }: { children: React.ReactNode; tone?: "default" | "warn" }) {
  return (
    <div
      className={cn(
        "placard-sunk flex gap-3 px-3.5 py-2.5",
        tone === "warn" && "border-warning/40",
      )}
    >
      <span
        className={cn(
          "num shrink-0 pt-px text-[9px] uppercase tracking-[0.14em]",
          tone === "warn" ? "text-warning" : "text-muted-foreground",
        )}
      >
        note
      </span>
      <p className="text-xs leading-relaxed text-muted-foreground">{children}</p>
    </div>
  );
}

export function GuessBadge({ children = "guess" }: { children?: React.ReactNode }) {
  return (
    <span className="num rounded-sm border border-warning/40 px-1.5 py-0.5 text-[9px] uppercase tracking-[0.12em] text-warning">
      {children}
    </span>
  );
}

export function MeasuredBadge() {
  return (
    <span className="num rounded-sm border border-success/40 px-1.5 py-0.5 text-[9px] uppercase tracking-[0.12em] text-success">
      measured
    </span>
  );
}

export function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="block space-y-1.5">
      <span className="eyebrow block">{label}</span>
      {children}
      {hint && <span className="block text-[11px] leading-relaxed text-muted-foreground">{hint}</span>}
    </label>
  );
}

export function SectionTitle({ eyebrow, title, right }: { eyebrow?: string; title: string; right?: React.ReactNode }) {
  return (
    <div className="flex items-end justify-between gap-3">
      <div className="min-w-0">
        {eyebrow && <p className="eyebrow">{eyebrow}</p>}
        <h2 className="display-mid mt-1 truncate text-xl text-foreground">{title}</h2>
      </div>
      {right}
    </div>
  );
}

/* Key/value row for machine data. */
export function Readout({ label, value, tone }: { label: string; value: React.ReactNode; tone?: "warn" | "alert" }) {
  return (
    <div className="flex items-baseline justify-between gap-3 py-1">
      <span className="eyebrow">{label}</span>
      <span
        className={cn(
          "num text-right text-xs text-foreground",
          tone === "warn" && "text-warning",
          tone === "alert" && "text-primary",
        )}
      >
        {value}
      </span>
    </div>
  );
}

/* ---------- the strip ---------- */

/*
 * Sliding-ink segmented control - the web twin of the iOS app's StripControl.
 * A hairline strip; the active cell is inverted, and the ink block slides.
 */
export function Strip<T extends string>({
  options,
  value,
  onChange,
  className,
  size = "md",
}: {
  options: { id: T; label: string; disabled?: boolean }[];
  value: T;
  onChange: (v: T) => void;
  className?: string;
  size?: "sm" | "md";
}) {
  const idx = Math.max(0, options.findIndex((o) => o.id === value));
  const n = options.length;
  return (
    <div
      role="tablist"
      className={cn("placard-sunk relative isolate grid overflow-hidden p-0.5", className)}
      style={{ gridTemplateColumns: `repeat(${n}, 1fr)` }}
    >
      <span
        aria-hidden
        className="absolute inset-y-0.5 left-0.5 -z-10 rounded-[5px] bg-foreground transition-transform duration-300 [transition-timing-function:var(--ease-snap)]"
        style={{ width: `calc((100% - 4px) / ${n})`, transform: `translateX(${idx * 100}%)` }}
      />
      {options.map((o) => (
        <button
          key={o.id}
          role="tab"
          aria-selected={o.id === value}
          disabled={o.disabled}
          onClick={() => {
            tap();
            onChange(o.id);
          }}
          className={cn(
            "num press z-0 truncate uppercase tracking-[0.1em] transition-colors duration-300",
            size === "sm" ? "px-2 py-1.5 text-[9px]" : "px-2.5 py-2 text-[10px]",
            o.id === value ? "text-background" : "text-muted-foreground hover:text-foreground",
            o.disabled && "cursor-not-allowed opacity-40",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

/* ---------- rolling number ---------- */

/* A value that ticks over like an instrument, not a re-render. */
export function Rolling({ value, className }: { value: string; className?: string }) {
  const [display, setDisplay] = useState(value);
  const [flip, setFlip] = useState(false);
  const prev = useRef(value);
  useLayoutEffect(() => {
    if (prev.current === value) return undefined;
    prev.current = value;
    setFlip(true);
    const t = setTimeout(() => {
      setDisplay(value);
      setFlip(false);
    }, 90);
    return () => clearTimeout(t);
  }, [value]);
  return (
    <span
      className={cn("num inline-block transition-all duration-100", flip && "-translate-y-0.5 opacity-0", className)}
    >
      {display}
    </span>
  );
}
