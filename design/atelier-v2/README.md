# Tessera / Atelier

A sculpted graphite enclosure with a fine satin-bronze perimeter and recessed, replaceable optics. Designed body: **536 × 536 × 116 mm**, with a **480 × 480 mm active display**. The room is presentation staging.

Open **Tessera-Atelier.blend** in Blender. It contains the editable assembly, packed artwork, eight named cameras, component collections, and embedded verification notes. The Pi and bonnet use manufacturer CAD; other purchased parts range from dimensioned reconstructions to explicitly marked unresolved geometry. Read **MODEL-NOTES.txt** before using dimensions to order or fabricate anything.

The Frienda riser contacts the Pi header housing; the bonnet socket contacts the riser. Exposed pins continue through the bonnet. This implements the requested fully seated arrangement using nominal seller dimensions, not a physical stack measurement.

## Views

- `01-hero.png` — finished exterior
- `02-listening-room.png` — contextual room presentation
- `03-corner-detail.png` — bronze, glass and sculpted shoulder
- `04-rear-service.png` — rear cover and guards removed
- `05-exploded.png` — separated assembly layers
- `06-dimensions.png` — front elevation and designed dimensions
- `07-controller.png` — official Pi and bonnet geometry with seated riser
- `08-album-mode.png` — full album artwork

The render depicts an appearance target. Optical performance, thermal performance, finished mounting capacity and electrical clearances have not been validated. The fuse-holder bodies, panel connector positions, inlet cutout and several fastening details still require physical dimensions.

## Primary references

- [Raspberry Pi 5 product information and CAD](https://pip.raspberrypi.com/categories/892-raspberry-pi-5)
- [Adafruit 6358 manufacturer CAD](https://github.com/adafruit/Adafruit_CAD_Parts/tree/main/6358%20Triple%20LED%20Matrix%20Bonnet)
- [Waveshare panel documentation](https://docs.waveshare.com/RGB-Matrix-Px-64x64)
- [Waveshare dimensional drawings](https://github.com/waveshareteam/RGB-Matrix-Px-xx/tree/main/hardware/dimensions/RGB-Matrix-Pxx-64x64)
- [Mean Well LRS-350 datasheet](https://www.meanwell.com/Upload/PDF/LRS-350/LRS-350-SPEC.PDF)
- [Active Cooler reference drawing](https://datasheets.raspberrypi.com/cooling/raspberry-pi-active-cooler-product-brief.pdf)
- [Frienda listing](https://www.amazon.com/dp/B084Q4W1PW)

Seller reference images and manufacturer drawings are retained under `references`. Each modeled object's custom properties describe its evidence or provisional status.

## Rebuild

Run `build_atelier.py` in Blender background mode, then `finish_views.py`. The latter replaces the grille with closed mesh cutters, refreshes embedded notes and renders selected camera names passed after `--`. It uses Metal on the author's Mac. The builder needs the converted reference meshes; the saved `.blend` is self-contained and does not need those conversion dependencies to open.
