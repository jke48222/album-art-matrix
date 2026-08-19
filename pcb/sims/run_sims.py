#!/usr/bin/env python3
"""Backplane design sims (ngspice): termination, IR drop, NTC inrush."""
import os
import subprocess

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)


def ngspice(deck, name):
    path = os.path.join(HERE, name + ".cir")
    with open(path, "w") as fh:
        fh.write(deck)
    r = subprocess.run(["ngspice", "-b", path], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{name}: {r.stderr[-400:]}")
    return r.stdout


def cols(fname):
    d = np.loadtxt(os.path.join(HERE, fname))
    return d


# ---- 1. HUB75 line termination: 25 MHz clock into 30 cm ribbon + panel ----
fig, ax = plt.subplots(figsize=(9, 5))
for rs in (0.1, 22, 33, 47):
    deck = f"""* term Rs={rs}
VDRV drv 0 PULSE(0 5 2n 1.5n 1.5n 18n 40n)
RDRV drv b {18}
RS   b   l0 {rs}
L1 l0 l1 25n
C1 l1 0 2.5p
L2 l1 l2 25n
C2 l2 0 2.5p
L3 l2 l3 25n
C3 l3 0 2.5p
L4 l3 l4 25n
C4 l4 0 2.5p
L5 l4 l5 25n
C5 l5 0 2.5p
L6 l5 lo 25n
CL lo 0 18p
.tran 0.05n 85n
.control
run
wrdata term_{int(rs)}.txt v(lo)
.endc
.end
"""
    ngspice(deck, f"term_{int(rs)}")
    d = cols(f"term_{int(rs)}.txt")
    ax.plot(d[:, 0] * 1e9, d[:, 1], label=f"Rs = {int(rs)} Ω")
ax.axhline(5, color="gray", lw=0.5); ax.axhline(0, color="gray", lw=0.5)
ax.axhline(3.5, color="green", lw=0.5, ls="--")
ax.axhline(1.5, color="red", lw=0.5, ls="--")
ax.set(xlabel="ns", ylabel="V at panel input",
       title="74AHCT245 → 30 cm ribbon → panel: series termination choice\n"
             "(dashed = FM6126A VIH/VIL comfort lines)")
ax.legend(); ax.grid(alpha=0.3)
fig.tight_layout(); fig.savefig("sim1_termination.png", dpi=110)

# ---- 2. IR drop: LRS-350-5 → trunk → fuse → harness → panel (worst) ------
fig, ax = plt.subplots(figsize=(9, 5))
R14, R18 = 0.0083, 0.021          # ohm/m
for trunk_m, style in ((1.0, "-"), (0.5, "--")):
    deck = f"""* irdrop trunk={trunk_m} m 14AWG round-trip, 12 A section
VSRC src 0 5.0
RT src sec {2 * trunk_m * R14}
* three panels, each: fuse+clips 7 mOhm, harness 0.4 m 18AWG round trip
RF1 sec f1 0.007
RH1 f1 p1 {2 * 0.4 * R18}
IP1 p1 0 4
RF2 sec f2 0.007
RH2 f2 p2 {2 * 0.4 * R18}
IP2 p2 0 4
RF3 sec f3 0.007
RH3 f3 p3 {2 * 0.4 * R18}
IP3 p3 0 4
.dc VSRC 5.0 5.35 0.025
.control
run
wrdata ir_{int(trunk_m * 10)}.txt v(p1)
.endc
.end
"""
    ngspice(deck, f"ir_{int(trunk_m*10)}")
    d = cols(f"ir_{int(trunk_m*10)}.txt")
    ax.plot(d[:, 0], d[:, 1], style,
            label=f"{trunk_m:.1f} m trunk (14 AWG), full-white section (12 A)")
ax.axhline(4.9, color="red", ls="--", lw=0.8, label="4.90 V panel floor")
ax.axhspan(5.0, 5.2, color="green", alpha=0.08)
ax.set(xlabel="LRS-350-5 output trim (V)", ylabel="V at panel terminals",
       title="IR drop at full blast: what to trim the supply to\n"
             "(green band = healthy panel voltage 5.0–5.2 V)")
ax.legend(); ax.grid(alpha=0.3)
fig.tight_layout(); fig.savefig("sim2_irdrop.png", dpi=110)

# ---- 3. Inrush: SL22 10005 NTC vs bare line into LRS input bulk ----------
fig, ax = plt.subplots(figsize=(9, 5))
for rlim, label, color in ((10.4, "with SL22 NTC (10 Ω cold)", "tab:green"),
                           (0.4, "no NTC (line + ESR only)", "tab:red")):
    deck = f"""* inrush R={rlim}
.model DBR D(IS=1e-9 N=1.8 RS=0.03)
VLINE ac 0 SIN(0 170 60 0 0 90)
RLIM ac a {rlim}
D1 a  dcp DBR
D2 0  dcp DBR
D3 dcn 0  DBR
D4 dcn a  DBR
RESR dcp c 0.15
CBULK c dcn 560u IC=0
RB1 dcp 0 1meg
RB2 dcn 0 1meg
RLOAD dcp dcn 120
.options reltol=0.003 abstol=1e-6 vntol=1e-4
.tran 5u 30m 0 10u uic
.control
run
wrdata inrush_{int(rlim * 10)}.txt i(VLINE)
.endc
.end
"""
    ngspice(deck, f"inrush_{int(rlim*10)}")
    d = cols(f"inrush_{int(rlim*10)}.txt")
    ax.plot(d[:, 0] * 1e3, -d[:, 1], color=color, label=label)
ax.set(xlabel="ms", ylabel="line current (A)",
       title="First AC cycles into the LRS-350-5 input bulk (~560 µF)\n"
             "why the SL22 goes in the mains line")
ax.legend(); ax.grid(alpha=0.3)
fig.tight_layout(); fig.savefig("sim3_inrush.png", dpi=110)

for f in ("sim1_termination.png", "sim2_irdrop.png", "sim3_inrush.png"):
    print("wrote", f)
