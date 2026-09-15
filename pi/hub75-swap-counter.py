"""A count of the frames the scan loop has finished scanning.

The library's mapper (pixels.c, map_byte_image_to_bcm) writes the buffer the
scan loop is not showing and flips scene->bcm_ptr; each scan loop (rpihub75.c
has three swap sites: two Pi 4 style ones that compare the pointer, and the
Pi 5 loop's own, gated on frame_ready) picks the flip up at the end of a
scanned frame. Nothing told the mapper's caller when that had happened, so
art_display could only map well under the frame rate and hope: two maps in
one scanned frame wrote the buffer on show, and the panel flashed black.

This adds one global, hub75_frames_scanned, one up at the end of every
scanned frame, at all three sites, right after the swap check. art_display
maps, reads the count, waits for it to move, maps again: a count that moved
after the flip means a scan ended after it, so the loop has re-read the
pointer and is showing the new buffer, and the other one is free to write.

After a fresh checkout of the library (after hub75-address-guard.py):
    python3 ~/album-art-matrix/pi/hub75-swap-counter.py
    cd ~/rpi-gpu-hub75-matrix && make libgpu
    cd ~/album-art-matrix/renderer && make -B
Safe to run again: it strips what it added before and adds it afresh.
"""
import re

p = "/home/pi/rpi-gpu-hub75-matrix/src/rpihub75.c"
s = open(p).read()

# ---- undo any earlier version of this patch --------------------------------
s = re.sub(r"\n/\* One up every time a scan loop takes a new buffer from the mapper\. The\n"
           r" \* renderer waits for this between maps \(album-art-matrix, art_display\.c\)\. \*/\n"
           r"volatile uint64_t hub75_swaps_taken = 0;\n", "", s)
s = re.sub(r"\n/\* One up at the end of every scanned frame.*?\*/\n"
           r"volatile uint64_t hub75_frames_scanned = 0;\n", "", s, flags=re.S)
s = re.sub(r"[ \t]*hub75_swaps_taken\+\+;\n", "", s)
s = re.sub(r"[ \t]*hub75_frames_scanned\+\+;\n", "", s)

# ---- the count ---------------------------------------------------------------
inc = "#include <stdatomic.h>\n"
assert s.count(inc) == 1, "stdatomic include not found once"
s = s.replace(inc, inc + """
/* One up at the end of every scanned frame, in every scan loop, after the
 * swap check. The renderer maps, then waits for this to move before it maps
 * again (album-art-matrix, art_display.c). */
volatile uint64_t hub75_frames_scanned = 0;
""", 1)

# ---- the two pointer-compare sites (Pi 4 loop, and the older Pi 5 path) ----
site = """            if (UNLIKELY(scene->bcm_ptr != last_pointer)) {
                last_pointer = scene->bcm_ptr;
                bcm_signal = (last_pointer) ? scene->bcm_signalB : scene->bcm_signalA;
            }
"""
assert s.count(site) == 2, f"expected two pointer-compare swap sites, found {s.count(site)}"
s = s.replace(site, site + "            hub75_frames_scanned++;\n")

# ---- the Pi 5 loop's own site, gated on frame_ready ------------------------
site5 = """\tif (!(before & 1u)) {
\t\tlast_pointer = scene->bcm_ptr;
\t\tbcm_signal = (last_pointer) ? scene->bcm_signalB : scene->bcm_signalA;
\t}
"""
assert s.count(site5) == 1, f"expected one frame_ready swap site, found {s.count(site5)}"
s = s.replace(site5, site5 + "\thub75_frames_scanned++;\n")

open(p, "w").write(s)
print("frames-scanned count at all three swap sites")
