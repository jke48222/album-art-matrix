# Measuring per-channel white balance (art pipeline step 4)

Why: HUB75 primaries are heavily green/blue-biased. Typical correction is
around R 1.00 / G 0.75 / B 0.55 — but measure YOURS. This is the step that
separates "album art" from "cyan mush".

Kit: the spare **Pico 2 W** + the TCS34725 breakout (solder its header strip),
three jumpers, USB cable. No Pi involvement — works at the bench.

1. Wire TCS34725 -> Pico: VIN->3V3 OUT (pin 36), GND->GND (38), SDA->GP4 (6),
   SCL->GP5 (7).
2. Flash MicroPython (RPI_PICO2_W build), then:
   `mpremote cp scripts/pico_colorimeter.py :main.py && mpremote repl`
3. Panel warm-up: run the renderer at working brightness for 10 minutes.
4. `python scripts/show_white.py --sink pi` — full white, NO white balance.
5. Hold the sensor flat against the panel face (or ~20 mm off the bare LEDs),
   shaded from room light. The REPL streams suggested gains continuously.
6. Put the settled numbers in config.toml [whitebalance], restart the brain,
   and compare the panel to the album cover on your phone — the deliverable.

(The gains target equal sensor response — refine toward D65 by eye if the
result reads warm. Alternative host: wire the sensor to the Pi's I2C pins 3/5
and read it there; the Pico route just keeps it grab-and-go.)

Eyeball fallback (no sensor yet): show a white-heavy sleeve, phone next to
panel with the same cover, nudge g down until white stops looking minty, then
b until it stops looking icy. Start from 1.00 / 0.75 / 0.55.
