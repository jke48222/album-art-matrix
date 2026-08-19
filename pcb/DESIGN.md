# matrix-backplane rev A — one board instead of the parts pile

Replaces: Triple Bonnet + riser, 2 bus bars, 9-10 fuse holders, panel screw-
terminal spaghetti, VEML7700 breakout, and (jumpered) the Pi's separate USB-C
supply. Does NOT replace: Pi, panels, the two Mean Well PSUs, SD, tools,
TCS34725 (that's a handheld calibration tool — stays on the Pico).

## Architecture
One 2-layer, 2 oz-copper board (~170×110 mm) mounted behind the center panel.
Pi 5 mounts on standoffs onto a 2×20 socket. Wall side: 3 HUB75 ribbons out,
9 fused panel-power drops out, 3 12 A trunks in from the LRS-350-5.

```
LRS-350-5 ──trunk1(12A)──▶ [TB1] ─┬─[F1 10A]─▶ [PNL1] ─▶ panel 1
   (5 V)  ──trunk2(12A)──▶ [TB2]  ├─[F2 10A]─▶ [PNL2]      ...
          ──trunk3(12A)──▶ [TB3]  └─[F3 10A]─▶ [PNL3]   (×3 sections = 9)
                                  bulk: 2×1000 µF + MLCC per section
Pi 40-pin ──26 GPIO──▶ 4× 74AHCT245 ──33 Ω arrays──▶ 3× HUB75 IDC (16p)
        └── I2C0 (GPIO0/1) ──▶ VEML7700 on-board + 2× JST-SH (StemmaQT)
JP1 (default OPEN): VP1 ──5 A polyfuse + SMBJ5.0A TVS──▶ Pi 5 V header pins
```

## Signal design
- **Pinout = hzeller "regular" 3-parallel mapping** (build bitslip6 with
  `-DHZELLER=1` instead of ADA_3HAT — proven mapping, open-source lineage
  from the active-3 adapter). Shared: CLK=17 LAT=4 OE=18 A=22 B=23 C=24 D=25
  E=15. Chain1 R1/G1/B1 R2/G2/B2 = 11/27/7 8/9/10. Chain2 = 12/5/6 19/13/20.
  Chain3 = 14/2/3 26/16/21. Uses ALL of BCM 2-27 (I2C1 included — hence:)
- **Sensors ride I2C0 on GPIO0/1** (HAT-EEPROM pins; free because this IS the
  hat). `dtoverlay=i2c0` on the Pi; VEML7700 @0x10, StemmaQT for anything else.
- 74AHCT245 (HCT input threshold ≈2.0 V, so the Pi's 3.3 V drives it; outputs
  are clean 5 V for the panels). One chip per chain's 6 data lines, one chip
  for the 8 shared lines. Unused inputs strapped to GND.
- 33 Ω series termination at every buffer output (value from sims/ — damps
  ribbon ringing; shared lines drive 3 ribbon loads).
- E-line: solder jumpers per port put E on IDC pin 8 (default) or pin 4;
  the unused one strapped to GND. Same trick as the Adafruit switch.

## Power design
- Three independent sections mirror the three chains: 12 A trunk each dodges
  a 36 A board trunk entirely; each drop fused (ATO blade, 10 A) at the board
  edge, screw terminal per panel. Star point: section grounds meet at one
  copper spine tied to the Pi ground pins — the "weak Pi ground" glitch
  killer, in copper.
- Bulk per section: 2× 1000 µF low-ESR + 4× 22 µF MLCC (board) — panels add
  their own ~1200 µF each; the SL22 NTC stays in the LRS AC line (mains does
  NOT touch this board).
- JP1 closed = Pi powered from section 1 through a 5 A polyfuse + TVS —
  deletes the 27 W USB-C but bypasses the Pi's own input protection; ship
  rev A with it OPEN, close it after the wall proves stable.

## Fab + economics (honest)
JLCPCB 2-layer 2 oz, SMD-assembled (buffers, arrays, MLCCs, TVS, VEML7700),
through-hole (IDC shrouds, terminals, fuse clips, electrolytics, 2×20) hand-
soldered — an evening with the Pinecil. Estimate: 5 bare boards ~$30 + 2×
assembly ~$70 + THT parts ~$25 ≈ **$100-140 for two working backplanes**, vs
~$50 of parts replaced. You build this because it turns the wall's guts into
a product, not to save money — and the spare board is real insurance.

## Files
- `circuit.py` — the whole circuit as data; emits `backplane.net` (KiCad
  netlist), `bom.csv`, and a connectivity report. Run after edits.
- `sims/run_sims.py` — ngspice: (1) termination value on the ribbon,
  (2) IR drop source→panel at full blast, (3) NTC inrush. Emits PNGs.
- Layout: KiCad 9 project (next session) — import `backplane.net`, place per
  this doc, 2 oz pours, DRC vs JLC rules, export gerbers + CPL.
