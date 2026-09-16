import type { NowPlaying, NowPlayingSource, SourceConfig } from "../types";
import { fetchJson, status, TransportError } from "./base";

const PLACEHOLDER = "2a96cbd8b46e442fc41c2b86b821562f"; // Last.fm's "no image" star

// What these two services actually send back, as much of it as this file
// reads. Everything is optional: it is someone else's JSON, and the code
// below already treats every field as missing until proven otherwise.
type MusicBrainzReleases = { releases?: { id?: string }[] };

type LastfmText = { "#text"?: string; name?: string };
type LastfmTrack = {
  "@attr"?: { nowplaying?: string };
  image?: { size?: string; "#text"?: string }[];
  artist?: LastfmText;
  album?: LastfmText;
  mbid?: string;
  name?: string;
};
type LastfmBody = {
  error?: number;
  message?: string;
  recenttracks?: { track?: LastfmTrack[] | LastfmTrack };
};

/** Cover Art Archive fallback by release search through MusicBrainz. */
async function coverArtArchive(artist: string, album: string): Promise<string | null> {
  if (!artist || !album) return null;
  try {
    const q = encodeURIComponent(`release:"${album}" AND artist:"${artist}"`);
    const { body } = await fetchJson(
      `https://musicbrainz.org/ws/2/release?query=${q}&fmt=json&limit=1`,
    );
    const id = (body as MusicBrainzReleases | undefined)?.releases?.[0]?.id;
    if (!id) return null;
    return `https://coverartarchive.org/release/${id}/front-1200`;
  } catch {
    return null;
  }
}

export const lastfmSource: NowPlayingSource = {
  id: "lastfm",
  label: "Last.fm",
  description:
    "Scrobble fallback that catches players nothing else sees. Polls user.getRecentTracks.",

  probe(cfg: SourceConfig) {
    const user = String(cfg.config.username ?? "").trim();
    const key = String(cfg.config.apiKey ?? "").trim();
    if (!user || !key) {
      return status(
        "lastfm",
        "needs-setup",
        "Enter your Last.fm username and API key. Both stay on this device.",
      );
    }
    return status("lastfm", "disconnected", `Ready to poll recent tracks for ${user}.`);
  },

  async getCurrent(cfg: SourceConfig): Promise<NowPlaying | null> {
    const user = String(cfg.config.username ?? "").trim();
    const key = String(cfg.config.apiKey ?? "").trim();
    if (!user || !key) return null;
    const url = `https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=${encodeURIComponent(
      user,
    )}&api_key=${encodeURIComponent(key)}&format=json&limit=1`;
    const { status: code, body } = await fetchJson(url);
    if (code >= 400) throw new TransportError(`Last.fm returned HTTP ${code}.`, "http", code);
    const b = body as LastfmBody | undefined;
    if (b?.error) throw new TransportError(`Last.fm: ${b.message}`, "http");
    const list = b?.recenttracks?.track;
    const track: LastfmTrack | undefined = Array.isArray(list) ? list[0] : list;
    if (!track) return null;
    const nowPlaying = track["@attr"]?.nowplaying === "true";
    if (!nowPlaying) return null;

    const images = track.image ?? [];
    const best = images[images.length - 1]?.["#text"] ?? "";
    let artUrl: string | null = best && !best.includes(PLACEHOLDER) ? best : null;
    const artist = track.artist?.["#text"] ?? track.artist?.name ?? "Unknown artist";
    const album = track.album?.["#text"] ?? "";
    if (!artUrl) artUrl = await coverArtArchive(artist, album);

    return {
      trackId: `lastfm:${track.mbid || `${artist}-${track.name}`}`,
      title: track.name ?? "Unknown title",
      artist,
      album,
      artUrl,
      progressMs: null,
      durationMs: null,
      isPlaying: true,
      tier: "user.getRecentTracks",
    };
  },
};
