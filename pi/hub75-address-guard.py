"""The bottom-row ghost, and the four clocks of darkness that fix it.

The panel library (bitslip6/rpi-gpu-hub75-matrix, checked out at
~/rpi-gpu-hub75-matrix on the Pi) puts each row's new address on the bus in
the same write that turns the output back on. The row decoder takes a moment
to settle, and for that moment the previous row is still selected with the
next row's data on the column drivers. Every row ghosts faintly onto its
neighbour, which nobody sees; at the wrap from row 31 to row 0 the "next
row" is 32, the middle of the picture, and the still-selected row is 63, so
the bottom row showed a dotted line in the middle row's colour on frames
that were exactly black there. A red clock left a red line; a blue one left
nothing.

This holds the output off for the first ADDR_GUARD_PX clocks of every row,
in both scan loops, so the address settles in the dark. It costs about six
percent of brightness, which the panel cap in the app gives back.

After a fresh checkout of the library:
    python3 ~/album-art-matrix/pi/hub75-address-guard.py
    cd ~/rpi-gpu-hub75-matrix && make libgpu
    cd ~/album-art-matrix/renderer && make -B
The renderer's Makefile links the home-directory build ahead of /usr/local,
so nothing needs root. The original is kept as src/rpihub75.c.orig.
"""
p="/home/pi/rpi-gpu-hub75-matrix/src/rpihub75.c"; s=open(p).read()
def rep(a,b):
    global s
    assert s.count(a)==1, a[:60]
    s=s.replace(a,b)
rep("""                    //const int guard = (x < guard_px) || ((width - 1 - x) < guard_px);
                    //const uint32_t oe_mask = (guard) ? 0u : jitter_mask[jitter_idx];
                    const uint32_t oe_mask = jitter_mask[jitter_idx];""",
"""                    /* Output OFF for the first few clocks of every row. The row
                     * address changes on the first write of a row while the
                     * previous row is still selected in the decoder; with the
                     * output on, that row shows the next row's data for the
                     * settling time. At the wrap (31 -> 0) the bottom row
                     * showed the middle row's colour as a dotted line. */
                    const uint32_t oe_mask = (x < ADDR_GUARD_PX) ? PIN_OE : jitter_mask[jitter_idx];""")
rep("""                    uint32_t v = bcm_signal[offset] | addr_map[y] | jitter_mask[jitter_idx];
                    io_write_barrier();
                    rio->Out = v;                     // clk low """,
"""                    uint32_t v = bcm_signal[offset] | addr_map[y]
                               | ((x < ADDR_GUARD_PX) ? PIN_OE : jitter_mask[jitter_idx]);
                    io_write_barrier();
                    rio->Out = v;                     // clk low """)
rep("""    //const uint32_t guard_px = 4;   /* do not change OE in first/last N pixels of a row */""",
"""    /* clocks of darkness at the start of every row, for the address to settle */
    #define ADDR_GUARD_PX 4u""")
open(p,"w").write(s); print("guard in both scan loops")
