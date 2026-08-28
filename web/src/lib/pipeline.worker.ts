/// <reference lib="webworker" />
import { runPipeline } from "./pipeline";
import type { PipelineParams } from "./types";

interface Req {
  id: number;
  rgba: ArrayBuffer;
  width: number;
  height: number;
  params: PipelineParams;
}

self.onmessage = (e: MessageEvent<Req>) => {
  const { id, rgba, width, height, params } = e.data;
  try {
    const result = runPipeline(new Uint8ClampedArray(rgba), width, height, params);
    // Steps may alias the same ArrayBuffer (e.g. a step that returns the final
    // buffer); a transfer list must not contain duplicates.
    const transfers = [
      ...new Set<ArrayBuffer>([
        result.balanced.buffer as ArrayBuffer,
        result.unbalanced.buffer as ArrayBuffer,
        ...result.steps.map((s) => s.buffer.buffer as ArrayBuffer),
      ]),
    ];

    (self as unknown as Worker).postMessage({ id, ok: true, result }, transfers);
  } catch (err) {
    (self as unknown as Worker).postMessage({
      id,
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    });
  }
};
