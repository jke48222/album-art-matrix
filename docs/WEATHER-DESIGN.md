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

The same visual direction at 64 and 192 pixels: muted atmospheric gradients,
layered terrain, soft cloud density with crown lighting, and subtle grain.
Cloud sprites and static landscapes are cached. At 192 pixels the temperature
and labeled high/low have their own space above a six-hour forecast shelf;
hour labels use the location's UTC offset. Existing weather modes, particles,
solar movement, moon phase and stale indicators remain supported.

Changing location hides the old forecast until the new location has data.

## Verification and previews

- Simulator Debug and Release builds, plus direct Swift decoding checks for
  current, legacy, and empty weather responses.
- `brain/tests/test_weather.py`: nine tests, including every WMO code by day
  and night at both sizes, negative temperatures, cloud-cache reuse, timezone
  propagation and location changes.
- Warm rain rendering measured around 0.21 ms/frame at 64 pixels and 1.76 ms/frame
  at 192 pixels on the development Mac. This is not a Raspberry Pi benchmark.
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
