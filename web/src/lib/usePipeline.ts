import { useCallback, useEffect, useRef, useState } from "react";
import { runPipeline } from "./pipeline";
import type { PipelineParams, PipelineResult } from "./types";
import type { RgbaImage } from "./patterns";

/** Runs the pipeline in a Web Worker with transferable buffers, falling back to inline. */
export function usePipelineWorker() {
  const workerRef = useRef<Worker | null>(null);
  const idRef = useRef(0);
  const pending = useRef(new Map<number, (r: PipelineResult) => void>());
  const rejects = useRef(new Map<number, (e: Error) => void>());
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let worker: Worker | null = null;
    try {
      worker = new Worker(new URL("./pipeline.worker.ts", import.meta.url), { type: "module" });
      worker.onmessage = (e: MessageEvent<any>) => {
        const { id, ok, result, error } = e.data;
        if (ok) pending.current.get(id)?.(deserialise(result));
        else rejects.current.get(id)?.(new Error(error));
        pending.current.delete(id);
        rejects.current.delete(id);
      };
      workerRef.current = worker;
    } catch {
      workerRef.current = null;
    }
    return () => worker?.terminate();
  }, []);

  const run = useCallback(async (img: RgbaImage, params: PipelineParams): Promise<PipelineResult> => {
    setBusy(true);
    try {
      const worker = workerRef.current;
      if (!worker) {
        return runPipeline(img.data, img.width, img.height, params);
      }
      const id = ++idRef.current;
      const copy = new Uint8ClampedArray(img.data);
      const promise = new Promise<PipelineResult>((res, rej) => {
        pending.current.set(id, res);
        rejects.current.set(id, rej);
      });
      worker.postMessage(
        { id, rgba: copy.buffer, width: img.width, height: img.height, params },
        [copy.buffer],
      );
      return await promise;
    } finally {
      setBusy(false);
    }
  }, []);

  return { run, busy };
}

function deserialise(result: any): PipelineResult {
  return {
    ...result,
    balanced: new Uint8Array(result.balanced),
    unbalanced: new Uint8Array(result.unbalanced),
    steps: result.steps.map((s: any) => ({ ...s, buffer: new Uint8Array(s.buffer) })),
  };
}
