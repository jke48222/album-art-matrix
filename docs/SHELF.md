# The Discogs shelf

Connect a Discogs username and personal access token on Tessera's Shelf
page. The wall copies folder 0 in pages of 100, resumes an interrupted sync,
and refreshes every six hours. Its last good collection stays available
when Discogs or the network is down. The token is stored with the other wall
service credentials in a mode-0600 file and is never returned by the API.

## Matching and the wall mark

Album and artist matching removes case, punctuation, accents, bracketed
edition text and `feat.` suffixes. It requires an exact normalized album and
artist, or a MusicBrainz release-group identifier when one is present. Only
vinyl formats count. When more than one pressing matches, the phone shows
all of them instead of guessing. Album-only matching cannot identify which
pressing is physically playing, and the UI says so.

With `shelf_mark` on, a streamed album that is also on the shelf gets a disc
in the lower-right corner. Records named through the room microphone and
AirPlay do not get the streamed-ownership mark. At 64 the glyph occupies a
5 by 5 box, inset two pixels, with a one-pixel centre hole. At 192 it occupies
11 by 11, inset six pixels, with a larger centre hole. Its ink comes from the
sleeve palette. The mark is added before the selected finish and normal
white balance, including art, disc and lyrics faces.

Run `.venv/bin/python -m scripts.render_shelf`. The verified fixture is a
muted navy photograph with a rust central block. At 64, the warm ownership
disc occupies x=57..61 and y=57..61. At 192, it occupies x=175..185 and
y=175..185. Both retain black or photographic pixels in the spindle hole.

## Phone and API

Services and Settings both open the Shelf page. Its large collection count,
sync state, current pressing block, credential form, search field and cover
list use the existing paper, ink, Archivo and IBM Plex Mono system. Loading,
empty, disabled, offline, syncing and populated states are explicit. The
Room page adds a compact `ON YOUR SHELF` pressing line under the track, with
year, label, country, catalogue number and lowest marketplace price. Tapping
a record opens the Discogs release.

`GET /shelf` returns sync state, current matches and the collection. Each
row has title, artists, year, labels, formats, country, cover, rating, release
URL, journal play count and cached marketplace stats. `GET /shelf/current`
returns only the current matches. `/services.discogs` returns status without
the token. The first page appears after one Discogs request; a full initial
sync takes roughly 1.1 seconds per page plus network time. Current-release
details and marketplace stats are fetched after the match, never on the
render loop. Marketplace stats are cached for one hour.

Offline tests exercise a 40-release fixture with punctuation, accents,
brackets, multi-artist names and edition text; exclude CD-only rows; cover
the MBID fallback; resume a two-page sync from disk; verify mode 0600; and
measure both glyphs. A live collection sync, marketplace price and physical
phone installation need the owner's Discogs token and iPhone signing account.

Enable `[features] shelf = true`. `config.example.toml` documents the mark
default; credentials are entered only on the phone. No dependency beyond
the existing Requests and Pillow packages is added.
