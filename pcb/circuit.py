#!/usr/bin/env python3
"""matrix-backplane rev A — the whole circuit as data.

Emits: backplane.net (KiCad S-expr netlist pcbnew can import), bom.csv,
and a human connectivity report. Edit the data, re-run, re-import.
"""
import csv
import os
from collections import defaultdict

OUT = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- pin maps
# BCM -> Pi 40-pin header physical pin
BCM = {0: 27, 1: 28, 2: 3, 3: 5, 4: 7, 5: 29, 6: 31, 7: 26, 8: 24, 9: 21,
       10: 19, 11: 23, 12: 32, 13: 33, 14: 8, 15: 10, 16: 36, 17: 11,
       18: 12, 19: 35, 20: 38, 21: 40, 22: 15, 23: 16, 24: 18, 25: 22,
       26: 37, 27: 13}
PI_5V, PI_3V3 = (2, 4), (1, 17)
PI_GND = (6, 9, 14, 20, 25, 30, 34, 39)

# hzeller "regular" 3-parallel mapping (bitslip6: -DHZELLER=1)
SHARED = {"CLK": 17, "LAT": 4, "OE": 18, "A": 22, "B": 23, "C": 24,
          "D": 25, "E": 15}
CHAIN = {1: {"R1": 11, "G1": 27, "B1": 7, "R2": 8, "G2": 9, "B2": 10},
         2: {"R1": 12, "G1": 5, "B1": 6, "R2": 19, "G2": 13, "B2": 20},
         3: {"R1": 14, "G1": 2, "B1": 3, "R2": 26, "G2": 16, "B2": 21}}
# HUB75 16-pin IDC: signal -> connector pin (E via solder jumper, dflt pin 8)
HUB75 = {"R1": 1, "G1": 2, "B1": 3, "GND4": 4, "R2": 5, "G2": 6, "B2": 7,
         "E": 8, "A": 9, "B": 10, "C": 11, "D": 12, "CLK": 13, "LAT": 14,
         "OE": 15, "GND16": 16}

# ---------------------------------------------------------------- builders
parts, nets = {}, defaultdict(list)


def part(ref, value, footprint, mpn="", note=""):
    parts[ref] = {"value": value, "footprint": footprint, "mpn": mpn,
                  "note": note}
    return ref


def wire(net, ref, pin):
    nets[net].append((ref, str(pin)))


# ------------------------------------------------------------------- parts
part("J_PI", "PI5_GPIO_2x20", "Connector_PinSocket_2.54mm:PinSocket_2x20_P2.54mm_Vertical", "generic 2x20 socket")
for i in (1, 2, 3, 4):
    part(f"U{i}", "74AHCT245PW", "Package_SO:TSSOP-20_4.4x6.5mm_P0.65mm", "SN74AHCT245PWR")
    part(f"C{i}", "100nF", "Capacitor_SMD:C_0603_1608Metric", "X7R 16V")
for i in (1, 2, 3):
    part(f"J_HUB{i}", "HUB75_IDC_2x8", "Connector_IDC:IDC-Header_2x08_P2.54mm_Vertical", "3M 30316-6002HB", f"chain {i} out")
    part(f"JP_E{i}", "E_PIN8_or_PIN4", "Jumper:SolderJumper-3_P1.3mm_Open_RoundedPad1.0x1.5mm", "", "E-line select")
    part(f"TB{i}", "TRUNK_IN_12A", "TerminalBlock_Phoenix:TerminalBlock_Phoenix_MKDS-1,5-2_1x02_P5.00mm_Horizontal", "MKDS 3/2-7.62 class", f"section {i} 5V in")
    part(f"LED{i}", "PWR_GREEN", "LED_SMD:LED_0805_2012Metric", "")
    part(f"RL{i}", "1k", "Resistor_SMD:R_0805_2012Metric", "")
# 7x 4-element 33R arrays cover 26 signals (28 elements, 2 spare)
for i in range(1, 8):
    part(f"RN{i}", "33Rx4", "Resistor_SMD:R_Array_Convex_4x0603", "YC164-JR-0733RL")
for s in range(1, 4):          # per section: bulk + fuses + panel outs
    for k in (1, 2):
        part(f"CB{s}{k}", "1000uF_10V", "Capacitor_THT:CP_Radial_D10.0mm_P5.00mm", "Panasonic FR 10V")
    for k in (1, 2, 3, 4):
        part(f"CM{s}{k}", "22uF_10V", "Capacitor_SMD:C_1206_3216Metric", "X5R")
for i in range(1, 10):
    part(f"F{i}", "ATO_FUSE_10A", "Fuse:Fuseholder_Blade_ATO_Littelfuse_Pudenz_2", "Keystone 3557 clips x2", f"panel {i}")
    part(f"J_PNL{i}", "PANEL_5V_OUT", "TerminalBlock_Phoenix:TerminalBlock_Phoenix_MKDS-1,5-2_1x02_P5.00mm_Horizontal", "", f"panel {i} 5V")
part("JP1", "PI_PWR_EN", "Jumper:SolderJumper-2_P1.3mm_Open_RoundedPad1.0x1.5mm", "", "close = Pi from VP1")
part("PF1", "POLYFUSE_5A", "Fuse:Fuse_Bourns_MF-R400", "MF-R500")
part("D1", "SMBJ5.0A", "Diode_SMD:D_SMB", "SMBJ5.0A")
part("U5", "VEML7700", "OptoDevice:Vishay_VEML7700", "VEML7700-TT", "ambient light")
part("C5", "100nF", "Capacitor_SMD:C_0603_1608Metric", "")
for i in (1, 2):
    part(f"J_QT{i}", "STEMMAQT_I2C0", "Connector_JST:JST_SH_SM04B-SRSS-TB_1x04-1MP_P1.00mm_Horizontal", "SM04B-SRSS-TB")
    part(f"RP{i}", "10k", "Resistor_SMD:R_0603_1608Metric", "", "I2C0 pullup")

# -------------------------------------------------------------------- nets
for p in PI_GND:
    wire("GND", "J_PI", p)
for p in PI_5V:
    wire("V5_PI", "J_PI", p)
for p in PI_3V3:
    wire("3V3", "J_PI", p)

# Buffers: U1..U3 = chain data, U4 = shared. A-side 2-9, B-side 18-11.
ABIT = [2, 3, 4, 5, 6, 7, 8, 9]
BBIT = [18, 17, 16, 15, 14, 13, 12, 11]
rn = [(f"RN{1 + i // 4}", 1 + i % 4) for i in range(28)]  # (array, element)
rn_i = 0


def buffered(u, slot, gpio_net, out_net):
    global rn_i
    wire(gpio_net, "J_PI", None)  # placeholder replaced below
    wire(gpio_net, u, ABIT[slot])
    arr, el = rn[rn_i]; rn_i += 1
    wire(f"{out_net}_D", u, BBIT[slot])          # buffer out -> array in
    wire(f"{out_net}_D", arr, el)                # array pin a
    wire(out_net, arr, 9 - el)                   # array pin b (mirrored)


# tie each GPIO net to its header pin exactly once
def gpio_net(bcm):
    n = f"GPIO{bcm}"
    if not any(r == "J_PI" for r, _ in nets[n]):
        nets[n] = [("J_PI", str(BCM[bcm]))]
    return n


nets.clear(); rn_i = 0
for p in PI_GND: wire("GND", "J_PI", p)
for p in PI_5V: wire("V5_PI", "J_PI", p)
for p in PI_3V3: wire("3V3", "J_PI", p)

def buf(u, slot, bcm, out_net):
    global rn_i
    wire(gpio_net(bcm), u, ABIT[slot])
    arr, el = rn[rn_i]; rn_i += 1
    wire(f"{out_net}_D", u, BBIT[slot])
    wire(f"{out_net}_D", arr, el)
    wire(out_net, arr, 9 - el)

for c in (1, 2, 3):                                   # chain data chips
    for slot, sig in enumerate(("R1", "G1", "B1", "R2", "G2", "B2")):
        buf(f"U{c}", slot, CHAIN[c][sig], f"H{c}_{sig}")
    for slot in (6, 7):                               # unused inputs low
        wire("GND", f"U{c}", ABIT[slot])
for slot, sig in enumerate(("A", "B", "C", "D", "E", "CLK", "LAT", "OE")):
    buf("U4", slot, SHARED[sig], f"SH_{sig}")

for i in (1, 2, 3, 4):                                # buffer housekeeping
    wire("V5_PI", f"U{i}", 20); wire("GND", f"U{i}", 10)
    wire("GND", f"U{i}", 19)                          # /OE enabled
    wire("V5_PI", f"U{i}", 1)                         # DIR = A->B
    wire("V5_PI", f"C{i}", 1); wire("GND", f"C{i}", 2)

for c in (1, 2, 3):                                   # HUB75 connectors
    j = f"J_HUB{c}"
    for sig in ("R1", "G1", "B1", "R2", "G2", "B2"):
        wire(f"H{c}_{sig}", j, HUB75[sig])
    for sig in ("A", "B", "C", "D", "CLK", "LAT", "OE"):
        wire(f"SH_{sig}", j, HUB75[sig])
    wire("GND", j, HUB75["GND16"])
    # E select: jumper common->pin8 default; pin4 strapped GND (swap = re-solder)
    wire("SH_E", f"JP_E{c}", 2)                       # common
    wire(f"H{c}_E8", f"JP_E{c}", 1); wire(f"H{c}_E8", j, HUB75["E"])
    wire(f"H{c}_E4", f"JP_E{c}", 3); wire(f"H{c}_E4", j, HUB75["GND4"])

for s in (1, 2, 3):                                   # power sections
    vp = f"VP{s}"
    wire(vp, f"TB{s}", 1); wire("GND", f"TB{s}", 2)
    for k in (1, 2):
        wire(vp, f"CB{s}{k}", 1); wire("GND", f"CB{s}{k}", 2)
    for k in (1, 2, 3, 4):
        wire(vp, f"CM{s}{k}", 1); wire("GND", f"CM{s}{k}", 2)
    wire(vp, f"RL{s}", 1); wire(f"LEDA{s}", f"RL{s}", 2)
    wire(f"LEDA{s}", f"LED{s}", 2); wire("GND", f"LED{s}", 1)
    for k in (1, 2, 3):
        i = (s - 1) * 3 + k
        wire(vp, f"F{i}", 1)
        wire(f"VF{i}", f"F{i}", 2)
        wire(f"VF{i}", f"J_PNL{i}", 1); wire("GND", f"J_PNL{i}", 2)

wire("VP1", "JP1", 1); wire("PIPWR_F", "JP1", 2)      # optional Pi power
wire("PIPWR_F", "PF1", 1); wire("V5_PI", "PF1", 2)
wire("V5_PI", "D1", 1); wire("GND", "D1", 2)

wire("3V3", "U5", 1); wire("GND", "U5", 2)            # VEML7700 + I2C0
wire("SDA0", "U5", 4); wire("SCL0", "U5", 3)
wire("3V3", "C5", 1); wire("GND", "C5", 2)
nets["SDA0"].append(("J_PI", str(BCM[0]))); nets["SCL0"].append(("J_PI", str(BCM[1])))
for i in (1, 2):
    wire("GND", f"J_QT{i}", 1); wire("3V3", f"J_QT{i}", 2)
    wire("SDA0", f"J_QT{i}", 3); wire("SCL0", f"J_QT{i}", 4)
wire("3V3", "RP1", 1); wire("SDA0", "RP1", 2)
wire("3V3", "RP2", 1); wire("SCL0", "RP2", 2)

# ------------------------------------------------------------------ output
def esc(s):
    return s.replace('"', "")

with open(os.path.join(OUT, "backplane.net"), "w") as fh:
    fh.write('(export (version "E")\n  (components\n')
    for ref, p in sorted(parts.items()):
        fh.write(f'    (comp (ref "{ref}") (value "{esc(p["value"])}") '
                 f'(footprint "{esc(p["footprint"])}"))\n')
    fh.write("  )\n  (nets\n")
    for code, (name, nodes) in enumerate(sorted(nets.items()), 1):
        fh.write(f'    (net (code "{code}") (name "{esc(name)}")\n')
        for ref, pin in nodes:
            fh.write(f'      (node (ref "{ref}") (pin "{pin}"))\n')
        fh.write("    )\n")
    fh.write("  )\n)\n")

with open(os.path.join(OUT, "bom.csv"), "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["ref", "value", "mpn", "footprint", "note"])
    for ref, p in sorted(parts.items()):
        w.writerow([ref, p["value"], p["mpn"], p["footprint"], p["note"]])

pins_used = sum(len(v) for v in nets.values())
print(f"parts: {len(parts)}   nets: {len(nets)}   pin connections: {pins_used}")
singles = [n for n, v in nets.items() if len(v) < 2]
print("single-node nets (should be none):", singles or "none")
gpios = sorted(int(n[4:]) for n in nets if n.startswith("GPIO"))
print(f"GPIOs consumed: {gpios}")
