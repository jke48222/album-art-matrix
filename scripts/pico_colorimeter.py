"""MicroPython colorimeter for the WB measurement — runs on the spare Pico 2 W
with the TCS34725 on I2C0. This is the whole job the Pico does; the Pi 5
drives the wall (no GPU / no bitslip6 on a Pico — it can't substitute).

Wiring (breakout -> Pico):
  VIN -> 3V3 OUT (pin 36)    GND -> GND (pin 38)
  SDA -> GP4 (pin 6)         SCL -> GP5 (pin 7)

Use:
  1. Flash MicroPython (RPI_PICO2_W build) via BOOTSEL drag-drop.
  2. mpremote cp scripts/pico_colorimeter.py :main.py
  3. mpremote repl   (or Thonny) — readings stream continuously.
  4. Panel shows scripts/show_white.py full-white; hold the sensor against
     the panel face, shaded from room light; read the suggested gains and
     put them in config.toml [whitebalance].
"""
import time

from machine import I2C, Pin

ADDR = 0x29
CMD = 0x80  # command bit, auto-increment not needed for 8-bit regs

i2c = I2C(0, sda=Pin(4), scl=Pin(5), freq=100_000)


def w8(reg, val):
    i2c.writeto_mem(ADDR, CMD | reg, bytes([val]))


def r16(reg):
    d = i2c.readfrom_mem(ADDR, CMD | reg, 2)
    return d[0] | (d[1] << 8)


chip = i2c.readfrom_mem(ADDR, CMD | 0x12, 1)[0]
assert chip in (0x44, 0x4D), "TCS34725 not found on I2C0 (got 0x%02x)" % chip

w8(0x00, 0x01)          # ENABLE: PON
time.sleep_ms(3)
w8(0x00, 0x03)          # ENABLE: PON | AEN
w8(0x01, 0xC0)          # ATIME: 154 ms integration
w8(0x0F, 0x01)          # CONTROL: 4x gain

print("clear     R     G     B   ->  gains r / g / b for config.toml")
while True:
    time.sleep_ms(250)
    c = r16(0x14)
    r = r16(0x16)
    g = r16(0x18)
    b = r16(0x1A)
    if c > 60000:
        print("saturated — lower panel brightness (-b) or shade the sensor")
    elif r and g and b:
        print("%5d %5d %5d %5d  ->  1.00 / %.2f / %.2f" % (c, r, g, b, r / g, r / b))
