# Weather: a window to outside

Weather now has its own native destination inside Settings → Weather. The art
follows the conditions rather than the album palette, while Technor, Switzer,
Martian Mono, warm ink, and the dark surfaces keep it part of Tessera.

## References

Studied these Mobbin screens directly, alongside web research:

- [Apple Weather](https://mobbin.com/screens/f7e0b42a-b5ea-4e48-9fb4-0ab3f04d7064): atmospheric sky behind a clear temperature hierarchy; forecast close to the current conditions.
- [(Not Boring) Weather](https://mobbin.com/screens/2f5d6c68-0085-4a81-b708-3754398d677f): large, expressive temperature as the central visual object.
- [Lumy](https://mobbin.com/screens/491f5781-df9b-46ea-86ec-fb258a83d369): restrained instruments and a dark, coherent surface palette.
- [Atmos, Diana L. Wong](https://www.dianalwong.com/atmos): landscape, weather and motion as a single composition; depth and coordinated colors make the scene more immersive.

These informed the hierarchy and atmosphere. The implementation uses original
procedural artwork; no reference screenshots or third-party image assets ship.

## Phone

- A condition-driven sky, sunset warmth, four engraved terrain layers, drifting
  cloud banks, real lunar phase, stars, wind-driven rain, snow, and fog.
- Select an hour to explore its scene and temperature. The “Now” button returns
  to the current conditions; measurements below remain explicitly “Right now.”
- Current temperature, daily range, feels-like, wind, cloud cover, precipitation,
  and a daylight arc. Celsius uses km/h and mm; Fahrenheit uses mph and inches.
- Location editing lives behind the place name. Errors remain inline. Pull to
  refresh retries a failed connection. Stale data is labeled as last known.
- The wall action displays the actual panel frame only when the wall is live
  and in weather mode. Forecast exploration never sends a future scene to it.
- Dynamic Type expands the layout; instruments become one column and forecast
  buttons widen at accessibility sizes. Decorative canvases are hidden from
  VoiceOver. Reduce Motion pauses the scene; inactive apps pause its timeline.
- Existing API fields are optional. Older wall software remains decodable.
  Updated wall software adds `utc_offset_s` so forecast and solar times use the
  saved city's offset; older software explicitly labels phone-local times.

## Matrix

The wall now follows the phone hero's composition: location at the top, large
Technor temperature, condition, high/low arrows and layered hills. It uses the
same Technor, Switzer and Martian Mono files as the app, bundled with their
licenses under `assets/fonts/weather/`. The previous bottom-left pixel-font
layout and separate forecast shelf have been removed.

The 64×64 adaptation uses only the city (without region), omits the micro heading
and enlarges the temperature and supporting labels. At 192×192 the full place
and current/last-known heading remain. Small labels and landscape detail cannot
have phone-resolution fidelity on 4,096 physical pixels; compare the actual
nearest-neighbour pixel preview, not an artificially smoothed enlargement.

The sky palettes, cloud drift, terrain frequencies, weather types, lunar epoch
and 75-minute golden-hour window follow `WeatherAtmosphere.swift`. The square
wall crops the tall phone hero and leaves interactive controls in the app.
Overcast nights no longer show stars on either surface. Clouds, terrain, fonts
and text are cached; rain/snow/fog and restrained storm illumination animate.
Future-hour exploration remains a labeled phone preview; current conditions
stay on the wall. An amber dot at 64px or LAST KNOWN WEATHER at 192px marks stale
weather. Missing values render as dashes rather than invented temperatures.

Changing location hides the old forecast until the new location has data.

## Verification and previews

- Simulator Debug and Release builds, plus direct Swift decoding checks for
  current, legacy, and empty weather responses.
- `brain/tests/test_weather.py`: eleven tests, including every WMO code by day
  and night at both sizes, negative temperatures, cloud-cache reuse, timezone
  propagation, location changes, the hero hierarchy, place/range/stale labels
  and signed three-digit temperature fitting.
- On the physical Pi, warm overcast rendering measured approximately 3.16 ms/frame
  at 64 pixels and 13.67 ms/frame at 192 pixels (20-frame sample).
- `python3 scripts/preview_weather.py` regenerates the deterministic comparison
  in `qa/weather/weather-parity.jpg`: 64px, 192px and the full-resolution wall
  composition. These are renderer outputs, not photographs of the LEDs.
- Simulator screenshots live in `qa/weather/`: main scene, night, rain, snow,
  empty/stale states, a selected forecast hour, Celsius, instruments, and
  accessibility text sizes. Hardware deployment is recorded below.

For repeatable simulator QA, launch the Debug app with `-weather-preview`.
Optional flags: `-weather-scene night|rain|snow|fog|storm|overcast|empty|stale|long`,
`-weather-hour`, `-weather-celsius`, `-weather-detail`, `-weather-large`.
The preview uses fixed sample data and never sends wall commands. The preview
entry and fixtures are excluded from Release builds.

## Deployment — 23 September 2026

Installed and launched the regular Tessera app (`com.jalenedusei.tessera`) on the
connected iPhone 18 Pro Max, built from current main plus this weather change.
Updated only `brain/weather.py` and `brain/art/weather.py` in the wall's active
`/home/pi/wall-claude` tree. Previous versions are backed up under
`~/.cache/tessera-weather-deploy-20260923/` on the Pi. Configuration, credentials,
and unrelated source files were left intact.

The new renderer passed smoke tests on the Pi at both 64 and 192 pixels. The
brain restarted under systemd and the live weather endpoint exposes the new
location offset. The renderer service remained active. These are operational
checks; the physical panel's color and the phone's touch flow were not measured.

## Weather parity correction — 23 September 2026

The user's phone screenshot and wall photograph revealed different compositions.
The renderer now follows the phone screenshot, with the explicit low-resolution
adaptations above. Scope: wall renderer, its three bundled fonts/licenses, one
phone sky correction, tests, preview script and design documentation. The full
app inventory is in [DESIGN-ROADMAP.md](DESIGN-ROADMAP.md).

The candidate renderer passed on the Pi before replacement. The previous
renderer is backed up in `~/.cache/tessera-weather-parity/weather.before.py`.
The regular Tessera app was built, installed and launched on the selected iPhone
18 Pro Max. Physical visual approval of this iteration remains open.

After deployment, both services were active and `/frame.raw` returned the new
64×64 hero (captured in `qa/weather/wall-live-64.png`). Weather was restored after
the brain restart. The final phone build includes the concurrently merged Show
me/Pictures update. The combined weather, Show and sting tests passed: 26 tests.
