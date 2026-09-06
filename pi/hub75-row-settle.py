#!/usr/bin/env python3
"""Row-change settle for the rpi-gpu-hub75-matrix scan loop (Pi 5 path).

On the row address change, the row just left keeps conducting for a while
(its driver turns off slowly) and, with the output on, shows the new row's
data: the bottom row of each half carried a faint copy of the top row of the
other half, red first because red LEDs need the least voltage. The address
guard (hub75-address-guard.py) blanks a few clocks, about 200 ns here, which
is marginal. This holds the output off for a real, tunable settle after every
change: HUB75_ADDR_SETTLE_NS, default 1000, 0 disables. It is dark time, so
the brightness cap pays it back (run_renderer.sh).

Run in ~/rpi-gpu-hub75-matrix after the guard patch, then `make libgpu` and
restart the renderer. Idempotent.
"""
import re, sys

p = "src/rpihub75.c"
s = open(p).read()
if "addr_settle_wait" in s:
    print("settle already in"); sys.exit(0)
if "#define ADDR_GUARD_PX 4u" not in s:
    print("apply hub75-address-guard.py first"); sys.exit(1)

d = s.index("#define ADDR_GUARD_PX 4u")
fn = max(m.start() for m in re.finditer(r"^\S[^\n]*\)\s*\{?\s*$", s[:d], re.M))
helpers = '''
/* Row-change settle. On the address change the row just left keeps
 * conducting for a while (its driver turns off slowly) and, with the output
 * on, shows the new row's data: the bottom row of each half carried a faint
 * copy of the top row of the other half. The output stays off for this long
 * after every change. Set HUB75_ADDR_SETTLE_NS to tune it; 0 disables. */
#include <stdlib.h>
static uint64_t addr_settle_ticks = 0;
static void addr_settle_init(void) {
    const char *e = getenv("HUB75_ADDR_SETTLE_NS");
    uint64_t ns = e ? (uint64_t)atoll(e) : 1000ull;
#if defined(__aarch64__)
    uint64_t f; __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
    addr_settle_ticks = ns * f / 1000000000ull;
#else
    addr_settle_ticks = ns / 20ull;
#endif
    fprintf(stderr, "hub75: row settle %llu ns\\n", (unsigned long long)ns);
}
static inline void addr_settle_wait(void) {
    if (!addr_settle_ticks) return;
#if defined(__aarch64__)
    uint64_t t0, t; __asm__ volatile("mrs %0, cntvct_el0" : "=r"(t0));
    do { __asm__ volatile("mrs %0, cntvct_el0" : "=r"(t)); } while (t - t0 < addr_settle_ticks);
#else
    for (uint64_t i = 0; i < addr_settle_ticks; i++) CLK_SETUP_DELAY();
#endif
}

'''
s = s[:fn] + helpers + s[fn:]
# two guard clocks are plenty once the settle is in; init once, settle every row
s = s.replace("#define ADDR_GUARD_PX 4u", "#define ADDR_GUARD_PX 2u\n    addr_settle_init();", 1)
d = s.index("#define ADDR_GUARD_PX 2u")
a = "                const uint32_t addr_bits = addr_map[y];\n"
i = s.index(a, d)
s = (s[:i + len(a)]
     + "                /* select the row with the output off, and let it settle */\n"
     + "                *reg_out = addr_bits | PIN_OE;\n"
     + "                addr_settle_wait();\n"
     + s[i + len(a):])
open(p, "w").write(s)
print("patched: row settle in, guard at two clocks")
