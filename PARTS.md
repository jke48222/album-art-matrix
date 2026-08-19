# All-stages bulk order — by store
Strategy: Micro Center (Marietta) walk-in for Pi + tools + shelf-luck items;
ONE AliExpress order for panels + wiring sundries (2-4 wk freight); ONE Mouser
order for the safety-critical power parts; Adafruit only for what the MC shelf
lacks. Prices checked 2026-08-19 where noted.

## 1 · Micro Center, today (18-min pickup / walk-in)
| Item | Link / SKU | Price |
|---|---|---|
| Pi 5 — **2 GB if on the shelf, else the 1 GB** (SC2162, SKU 959668, 16 in stock) | https://www.microcenter.com/product/704295/raspberry-pi-5-1gb · all variants: https://www.microcenter.com/search/search_results.aspx?Ntt=raspberry+pi+5 | $42.99 (1 GB) |
| MC house 32 GB microSD (the add-on on that page) | https://www.microcenter.com/product/658457 | $9.99 |
| Raspberry Pi Active Cooler | https://www.microcenter.com/search/search_results.aspx?Ntt=raspberry+pi+active+cooler | ~$6 |
| 27 W USB-C PSU — ONLY if no 27 W+ PD charger owned | https://www.microcenter.com/search/search_results.aspx?Ntt=raspberry+pi+27w | ~$14 |
| IEC power cord (cut it = the LRS mains pigtail) | https://www.microcenter.com/search/search_results.aspx?Ntt=iec+power+cord | ~$5 |
| Inland soldering iron/station + 63/37 solder | https://www.microcenter.com/search/search_results.aspx?Ntt=inland+soldering | ~$25-40 |
| Inland multimeter (DC-side checks) | https://www.microcenter.com/search/search_results.aspx?Ntt=inland+multimeter | ~$15-30 |
| Wire strippers, precision screwdrivers, heat-shrink kit, F-F jumper wires | search each; Inland versions exist | ~$25 |
| **Shelf-luck checks** (buy on sight, skips the Adafruit order): Adafruit Triple LED Matrix Bonnet #6358, TCS34725 breakout, any 64×64 P2.5/P3 HUB75 panel | https://www.microcenter.com/search/search_results.aspx?Ntt=adafruit+triple+led+matrix+bonnet · ?Ntt=tcs34725 · ?Ntt=hub75 | — |

## 2 · AliExpress — one bulk order (all stages, 2-4 week freight)
| Item | Search | Price |
|---|---|---|
| **10× P2.5 64×64 HUB75, 160×160 mm** (9 wall + 1 spare/bench) — SAME seller, SAME order, ask for same batch (mixed brightness bins = visible tile boundaries) | https://www.aliexpress.com/w/wholesale-P2.5-64x64-HUB75.html | ~$250-320 |
| Checklist per listing: ABCDE address, 1/32 scan, exactly 160×160 mm, conventional driver (FM6126A/SM16xxx) — **NOT ICN2053/2153/MBI515x**, indoor panel | | |
| 14 AWG silicone wire, 5 m red + 5 m black | https://www.aliexpress.com/w/wholesale-14awg-silicone-wire.html | ~$12 |
| 2× bus bars / power distribution blocks | https://www.aliexpress.com/w/wholesale-power-distribution-terminal-bus-bar.html | ~$10 |
| 10× ATC inline fuse holders (14 AWG) + 10 A blade fuse pack | https://www.aliexpress.com/w/wholesale-ATC-inline-fuse-holder-14awg.html | ~$12 |
| Ratcheting crimper (SN-48BS class) + fork/ring terminal kit | https://www.aliexpress.com/w/wholesale-SN-48BS-crimper.html | ~$20 |
| IEC C14 panel inlet with switch + fuse (S2 power box) | https://www.aliexpress.com/w/wholesale-iec-320-c14-switch-fuse.html | ~$4 |
| M3 screw/standoff assortment (panel mounting) | https://www.aliexpress.com/w/wholesale-m3-screw-standoff-assortment.html | ~$6 |
| Spare HUB75 IDC cables + 4-pin power harnesses | https://www.aliexpress.com/w/wholesale-hub75-16pin-idc-cable.html | ~$6 |
| TCS34725 breakout (if MC/Adafruit not used) | https://www.aliexpress.com/w/wholesale-TCS34725.html | ~$3 |
| VEML7700 breakout (S6 auto-brightness) | https://www.aliexpress.com/w/wholesale-VEML7700.html | ~$3 |
| Optional: mini USB mic (S3 fingerprint fallback path) | https://www.aliexpress.com/w/wholesale-mini-usb-microphone.html | ~$8 |

## 3 · Mouser — one order (safety-critical; do NOT AliExpress these)
| Item | Link | Price |
|---|---|---|
| Mean Well LRS-50-5 (S1 panel PSU) | https://www.mouser.com/ProductDetail/MEAN-WELL/LRS-50-5 | ~$16 |
| Mean Well LRS-350-5 (S2 wall PSU) | https://www.mouser.com/ProductDetail/MEAN-WELL/LRS-350-5 | ~$45 |
| SL22 10005 NTC inrush limiter | https://www.mouser.com/c/?q=SL22%2010005 | ~$3 |
Mean Well fakes are rampant on AliExpress; the mains side is the one place we
don't save $20.

## 4 · Adafruit — only for MC shelf gaps
Triple Bonnet #6358 ($9.95) + riser (~$2): https://www.adafruit.com/product/6358
Optional first-light-now panel #3649 ($54.95): https://www.adafruit.com/product/3649
Genuine TCS34725 #1334 ($7.95): https://www.adafruit.com/product/1334

## 5 · Amazon
Behringer UCA202 line-in (S3 ears, ~$30): https://www.amazon.com/s?k=Behringer+UCA202

## 6 · Local, at S6 (can't usefully pre-order)
3 mm opal acrylic diffuser + 3 mm "LED grey" smoked ND acrylic, cut 480×480 mm
(TAP Plastics or local shop); hardwood + French cleat + fasteners.

## Notes
- **1 GB Pi 5 verdict:** works for every on-device job in this build
  (~450-550 MB steady state: OS ~200 + renderer <100 + brain ~150 + fpcalc
  ~60 transient). bootstrap.sh now sets up zram; per-track beat-grid/section
  precompute runs on the Mac by design. Take the 2 GB for ~$7 more if it's on
  the shelf; don't make a second trip for it.
- Panel power never transits the bonnet; injection per panel from the bus bar
  at S2 (fused 14 AWG drops), NTC in the AC line, star ground at the PSU.
- Multimeter discipline: verify the LRS outputs on the DC side; don't probe
  mains with a budget meter.
