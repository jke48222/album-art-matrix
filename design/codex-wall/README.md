# Tessera walnut wall — Codex design

Open `tessera-wall-codex.blend` in Blender. Five cameras show the finished object, a staged listening room, a dimensioned front elevation, the rear with its cover removed, and the exploded assembly. Collections separate the enclosure, optical stack, panel bodies and 36,864 LED faces, support hardware, electronics, harness, cover and cleat. Images are packed into the file.

## Dimensions

The designed outside envelope is **528 × 528 × 110 mm**, plus **12 mm** between enclosure and wall. The nine **160 × 160 mm** panels form a **480 × 480 mm / 192 × 192 pixel** matrix at **2.5 mm pitch**. The front opening is **476 × 476 mm**: its 2 mm overlap on each edge retains the specified **480 × 480 × 3 mm** acrylic sheets. This hides the extreme outer pixel edges; a completely unobstructed 480 mm opening would require larger acrylic sheets and a revised retainer.

The opal sheet is separated from the LED plane by **15.5 mm**. A **1 mm** gap separates it from the smoked sheet. Both are independent objects. These optical spacings are design choices to prototype; no measured transmission, haze or LED brightness was available. The beauty render uses a separately labelled appearance plane based on `DiscAnimator` in this repository, not a simulation of the actual acrylic.

## Nominal stock and assembly

- Two walnut side members: 528 × 104 × 23 mm.
- Two walnut cross members: 482 × 104 × 23 mm, between the sides.
- Two front retaining stiles: 528 × 26 × 6 mm.
- Two front retaining crosspieces: 476 × 26 × 6 mm.
- Six aluminium panel support strips: 480 × 16 × 3 mm.
- Rear removable cover: 482 × 482 × 3 mm.
- Opal acrylic: 480 × 480 × 3 mm; smoked ND acrylic: same.
- 36 nominal M3 nylon standoffs, 20 mm long, at provisional panel mounting positions.
- Modelled ventilation: twenty 9 × 30 mm slots in each top/bottom structural rail, on 20 mm centres.

These are nominal concept dimensions, not a released cutting/drilling schedule. Joinery, kerf, timber movement, removable-retainer fastening, actual panel hole locations and support-to-frame brackets must be finalized from measured hardware. The aluminium strips show the support positions; their attachment hardware is not fabrication detailed.

## Hardware fidelity

The [Waveshare module outline and pitch](https://www.waveshare.com/wiki/RGB-Matrix-P2.5-64x64), [Mean Well 215 × 115 × 30 mm PSU envelope](https://www.meanwell.com/Upload/PDF/LRS-350/LRS-350-SPEC.PDF), and [Raspberry Pi 85 × 56 mm board outline](https://datasheets.raspberrypi.com/rpi5/raspberry-pi-5-mechanical-drawing.pdf) are sourced dimensions. The current project parts list and `docs/WALL-BUILD.md` determine component selection and nine-fuse / three-chain topology. The parked backplane PCB is not used.

The bus bars, inline fuse bodies, bonnet/cooler stack, connectors, IEC inlet, panel thickness, hole centres, cleat and PSU cosmetic details are simplified or provisional. The PSU grille dots are visual geometry, not actual holes. Do not derive mounting patterns or inlet cutouts from them. Confirm the bonnet clears the Active Cooler, supply fan clearance and enclosure temperature, final wire routing, mains-cover geometry and mounting load before building. The separate external 27 W USB-C Pi supply is retained; its cable exit is reserved but not a fabrication cutout. The optional microphone and colorimeter are not part of this enclosure model.

Wiring curves communicate topology and space allocation. They are not a validated harness, terminal pinout or electrical construction drawing. Several feed routes intentionally overlap visually; actual wires require separated routing, strain relief and measured lengths.

## Regenerate

From the repository root:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python design/codex-wall/build_scene.py
```

The build only writes inside `design/codex-wall`. The pre-existing `design/wall_model.py` is untouched. The embedded Blender text block `READ ME - dimensions and assumptions` carries the same fidelity distinctions into the model.
