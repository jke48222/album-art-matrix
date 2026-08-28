import { useEffect, useRef } from "react";
import { drawNearest, drawPreviewGrid, drawWall } from "@/lib/render";
import type { ViewMode } from "@/lib/types";

export function WallCanvas({
  buffer,
  size,
  mode,
  brightness,
  showGrid,
  showSeams,
  rawZoom,
  className,
}: {
  buffer: Uint8Array | null;
  size: number;
  mode: ViewMode;
  brightness: number;
  showGrid: boolean;
  showSeams: boolean;
  rawZoom: number;
  className?: string;
}) {
  const ref = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const buf = buffer ?? new Uint8Array(size * size * 3); // unlit = true black
    if (mode === "grid") drawPreviewGrid(canvas, buf, size, brightness, showGrid);
    else if (mode === "wall") drawWall(canvas, buf, size, size > 128 ? 6 : size > 64 ? 8 : 12, brightness, showSeams);
    else drawNearest(canvas, buf, size, Math.max(1, Math.round(rawZoom)), brightness);
  }, [buffer, size, mode, brightness, showGrid, showSeams, rawZoom]);

  return (
    <canvas
      ref={ref}
      className={`pixelated block h-auto w-full max-w-full bg-black ${className ?? ""}`}
      style={{ imageRendering: "pixelated" }}
    />
  );
}
