import type { NowPlaying, NowPlayingSource, SourceConfig } from "../types";
import { status, TransportError } from "./base";

/**
 * Authorization Code with PKCE. No client secret exists in this app, ever.
 * The user supplies their own Client ID; tokens live in localStorage on their device.
 */

const AUTH_URL = "https://accounts.spotify.com/authorize";
const TOKEN_URL = "https://accounts.spotify.com/api/token";
const SCOPES = "user-read-currently-playing user-read-playback-state";
const STORE_KEY = "aam.spotify.tokens";
const VERIFIER_KEY = "aam.spotify.verifier";

export interface SpotifyTokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  displayName?: string;
}

export function readTokens(): SpotifyTokens | null {
  if (typeof localStorage === "undefined") return null;
  try {
    const raw = localStorage.getItem(STORE_KEY);
    return raw ? (JSON.parse(raw) as SpotifyTokens) : null;
  } catch {
    return null;
  }
}

function writeTokens(t: SpotifyTokens | null) {
  if (t) localStorage.setItem(STORE_KEY, JSON.stringify(t));
  else localStorage.removeItem(STORE_KEY);
}

export function disconnectSpotify() {
  writeTokens(null);
}

function base64url(bytes: ArrayBuffer) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export async function beginSpotifyAuth(clientId: string) {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(48)).buffer);
  const challenge = base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  sessionStorage.setItem(VERIFIER_KEY, verifier);
  const redirectUri = `${window.location.origin}/sources`;
  const url = new URL(AUTH_URL);
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("scope", SCOPES);
  window.location.href = url.toString();
}

export async function completeSpotifyAuth(clientId: string, code: string) {
  const verifier = sessionStorage.getItem(VERIFIER_KEY);
  if (!verifier) throw new Error("PKCE verifier missing — start the connection again.");
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      grant_type: "authorization_code",
      code,
      redirect_uri: `${window.location.origin}/sources`,
      code_verifier: verifier,
    }),
  });
  const json = (await res.json()) as Record<string, unknown>;
  if (!res.ok) throw new Error(String(json.error_description ?? json.error ?? "Token exchange failed"));
  const tokens: SpotifyTokens = {
    accessToken: String(json.access_token),
    refreshToken: String(json.refresh_token ?? ""),
    expiresAt: Date.now() + Number(json.expires_in ?? 3600) * 1000,
  };
  writeTokens(tokens);
  try {
    const me = await fetch("https://api.spotify.com/v1/me", {
      headers: { Authorization: `Bearer ${tokens.accessToken}` },
    });
    if (me.ok) {
      const p = (await me.json()) as Record<string, unknown>;
      tokens.displayName = String(p.display_name ?? p.id ?? "");
      writeTokens(tokens);
    }
  } catch {
    /* account name is cosmetic */
  }
  sessionStorage.removeItem(VERIFIER_KEY);
  return tokens;
}

async function refresh(clientId: string, tokens: SpotifyTokens): Promise<SpotifyTokens> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      grant_type: "refresh_token",
      refresh_token: tokens.refreshToken,
    }),
  });
  const json = (await res.json()) as Record<string, unknown>;
  if (!res.ok) throw new TransportError("Spotify refresh failed — reconnect the account.", "http", res.status);
  const next: SpotifyTokens = {
    ...tokens,
    accessToken: String(json.access_token),
    refreshToken: json.refresh_token ? String(json.refresh_token) : tokens.refreshToken,
    expiresAt: Date.now() + Number(json.expires_in ?? 3600) * 1000,
  };
  writeTokens(next);
  return next;
}

export const spotifySource: NowPlayingSource = {
  id: "spotify",
  label: "Spotify",
  description: "Authorization Code with PKCE against your own Client ID. No secret is stored in this app.",

  probe(cfg: SourceConfig) {
    const clientId = String(cfg.config.clientId ?? "").trim();
    if (!clientId) return status("spotify", "needs-setup", "Paste your Spotify Client ID to connect.");
    const t = readTokens();
    if (!t) return status("spotify", "disconnected", "Client ID set. Not connected yet.");
    return status("spotify", "connected", `Connected${t.displayName ? ` as ${t.displayName}` : ""}.`);
  },

  async getCurrent(cfg: SourceConfig): Promise<NowPlaying | null> {
    const clientId = String(cfg.config.clientId ?? "").trim();
    let tokens = readTokens();
    if (!clientId || !tokens) return null;
    if (Date.now() > tokens.expiresAt - 30_000 && tokens.refreshToken) {
      tokens = await refresh(clientId, tokens);
    }

    const call = (t: SpotifyTokens) =>
      fetch("https://api.spotify.com/v1/me/player/currently-playing", {
        headers: { Authorization: `Bearer ${t.accessToken}` },
      });

    let res = await call(tokens);
    if (res.status === 401 && tokens.refreshToken) {
      tokens = await refresh(clientId, tokens);
      res = await call(tokens);
    }
    if (res.status === 429) {
      const wait = res.headers.get("Retry-After") ?? "?";
      throw new TransportError(`Rate limited by Spotify. Retry-After: ${wait} s.`, "http", 429);
    }
    if (res.status === 204) return null;
    if (!res.ok) throw new TransportError(`Spotify returned HTTP ${res.status}.`, "http", res.status);

    const body = (await res.json()) as any;
    const item = body?.item;
    if (!item) return null;
    const images: { url: string; width: number }[] = item.album?.images ?? [];
    const largest = images.slice().sort((a, b) => (b.width ?? 0) - (a.width ?? 0))[0];
    return {
      trackId: `spotify:${item.id}`,
      title: item.name ?? "Unknown title",
      artist: (item.artists ?? []).map((a: any) => a.name).join(", ") || "Unknown artist",
      album: item.album?.name ?? "",
      artUrl: largest?.url ?? null,
      progressMs: body.progress_ms ?? null,
      durationMs: item.duration_ms ?? null,
      isPlaying: Boolean(body.is_playing),
      tier: "Web API",
    };
  },
};
