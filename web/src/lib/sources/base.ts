import type { NowPlayingSource, SourceConfig, SourceId, SourceStatus } from "../types";

export function status(
  id: SourceId,
  state: SourceStatus["state"],
  detail: string,
  extra: Partial<SourceStatus> = {},
): SourceStatus {
  return {
    id,
    state,
    detail,
    lastPollAt: null,
    lastError: null,
    lastAnswerTier: null,
    ...extra,
  };
}

/** Transport concern kept out of adapter logic: fetch with timeout + typed failures. */
export class TransportError extends Error {
  constructor(
    message: string,
    public kind: "network" | "cors" | "http" | "parse" | "timeout",
    public statusCode?: number,
  ) {
    super(message);
  }
}

export async function fetchJson(
  url: string,
  init: RequestInit = {},
  timeoutMs = 6000,
): Promise<{ status: number; body: unknown; headers: Headers }> {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  let res: Response;
  try {
    res = await fetch(url, { ...init, signal: ac.signal });
  } catch (err) {
    clearTimeout(timer);
    if (ac.signal.aborted) throw new TransportError(`Timed out after ${timeoutMs} ms`, "timeout");
    // A browser cannot distinguish a CORS rejection from a dead host; say both.
    throw new TransportError(
      "Could not reach the endpoint. Either it is not running, or the browser blocked the response because it did not send an Access-Control-Allow-Origin header.",
      "cors",
    );
  }
  clearTimeout(timer);
  if (res.status === 204) return { status: 204, body: null, headers: res.headers };
  let body: unknown = null;
  const text = await res.text();
  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      throw new TransportError("The endpoint returned a body that is not valid JSON.", "parse", res.status);
    }
  }
  return { status: res.status, body, headers: res.headers };
}

export type { NowPlayingSource, SourceConfig };
