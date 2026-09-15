// art_display — push frames from a named pipe onto the HUB75 wall.
// Built against bitslip6/rpi-gpu-hub75-matrix (pi/bootstrap.sh installs it),
// with two small patches to the library, applied by scripts in pi/:
//   hub75-address-guard.py   the output held off while a row address settles
//   hub75-swap-counter.py    a count of the frames the scan loop has
//                            finished, which is what lets this map once per
//                            scanned frame (PACING, below)
//
// PROTOCOL. A writer opens the FIFO and streams frames back to back, each
// behind an eight-byte header: "TSRA", the panel brightness (1-254), the
// spatial dither strength in tenths (0-100), two spare. The read end is held
// open and re-opened only on EOF, so the brain can come and go while the
// wall keeps showing the last frame it sent.
//
// WHAT HAPPENS TO A FRAME. The library lights each colour of each LED for
// some number of its BIT_DEPTH equal slots per scanned frame: 64 slots at
// -d 64, so 64 levels of linear light, the first of them at sRGB 37. A dark
// brown wants a quarter of a slot of green and got none, which turned a
// sleeve's shadow into a field of lone red LEDs. So the brain's bytes are
// not handed to the library as they are. The last frame received is HELD,
// and once per scanned frame it is drawn again with TEMPORAL DITHERING: for
// every colour of every LED a running fraction is kept, and one slot more
// is lit on the frames where the fraction carries. Over a few frames the
// LED shows the light the brain asked for, to well under a slot. The
// dimmest fractions would blink slowly (a tenth of a slot is lit one frame
// in ten: 12 Hz at 120 fps), so fractions under DITHER_MIN are rounded
// instead. Every LED starts its fraction at its own phase, so a field
// shimmers rather than blinking in step. TEMPORAL_DITHER=0 turns it off and
// rounds, which is what the library did on its own.
//
// THE BRIGHTNESS CAP is applied here as well, not in the library. The
// library bakes -b into a lookup table once, at launch, so the cap in the
// frame header never reached the LEDs. The library now always runs at 254
// and this scales the slots it asks for, live: from PANEL_CAP at launch and
// from every frame's header after that. With the dither on, dimming keeps
// its fractions instead of throwing steps away.
//
// PACING. The library's mapper writes the buffer the scan loop is not
// showing, then flips a pointer; the scan loop picks the flip up at the end
// of its frame and, with the patch, counts every frame it finishes. Map,
// read the count, wait for it to move, map again: a count that moved after
// the flip means a scan ended after it, so the loop is showing the new
// buffer and the other is free. One map per scanned frame, never into the
// buffer on show. Before the count the only safe rate was well under the
// frame rate (60 Hz), because two maps inside one scanned frame wrote the
// buffer on show, which was black flashing. Should the count ever stop
// moving (a library without the patch), mapping falls back to a 60 Hz timer.
//
// THE LAST FRAME IS KEPT in /dev/shm (RAM, no card wear), at most once a
// second, and loaded at launch: a relaunch for a tuning knob comes back with
// the picture, not black, and needs nothing from the brain, which only
// resends a still picture when something changes.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>

#include <rpihub75/rpihub75.h>
#include <rpihub75/util.h>   // default_scene() lives here as of lib v0.2
#include <rpihub75/pixels.h>
#include <rpihub75/gpu.h>

// pi/hub75-swap-counter.py adds this to the library: one up at the end of
// every scanned frame, after the loop's swap check.
extern volatile uint64_t hub75_frames_scanned;

static const char *last_frame_path(void) {
    const char *p = getenv("LAST_FRAME");
    return p ? p : "/dev/shm/album-frame.last";
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static const char *fifo_path(void) {
    const char *p = getenv("FRAME_FIFO");
    return p ? p : "/tmp/album-frame.fifo";
}

static int env_int(const char *name, int dflt) {
    const char *v = getenv(name);
    if (!v || !*v) return dflt;
    char *end = NULL;
    long x = strtol(v, &end, 10);
    return (end && *end == 0) ? (int)x : dflt;
}

static double env_double(const char *name, double dflt) {
    const char *v = getenv(name);
    if (!v || !*v) return dflt;
    char *end = NULL;
    double x = strtod(v, &end);
    return (end && *end == 0) ? x : dflt;
}

// What the library's mapper actually reads, which is not what it was given.
//
// update_bcm_signal_64_rgb() in pixels.c takes six base pointers off the
// image every pixel: the top and bottom half of three ports, at
// width * (panel_height/2) pixels apart, and it does that whatever
// scene->num_ports says. A wall on one port hands it a third of that and it
// reads the other two thirds off the end of the buffer.
//
// One 64x64 panel over-read 24 KB past a 12 KB buffer for months and never
// faulted, because the heap had those pages. The first 192x64 frame (three
// panels on one port) over-read 73 KB and killed the renderer with SIGSEGV
// on the frame it mapped, which on the panel looks exactly like dead
// hardware: black, and a service that keeps restarting.
//
// So the staging buffer is always sized for the three ports the mapper is
// going to read, and calloc'd, so the ports that do not exist read as black
// instead of as whatever follows in memory. At three ports this is the frame
// size and costs nothing.
static size_t mapper_bytes(const scene_info *scene) {
    const size_t stride = (size_t)scene->stride;
    const size_t frame = (size_t)scene->width * scene->height * stride;
    const size_t six_halves =
        6 * (size_t)scene->width * ((size_t)scene->panel_height / 2) * stride;
    return frame > six_halves ? frame : six_halves;
}

// ---- the held frame --------------------------------------------------------
static pthread_mutex_t held_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *held_rgb = NULL;       // width * height * 3: the last frame in
static uint64_t held_seq = 0;          // one up per frame received
static atomic_int live_cap;            // the panel brightness, 1-254

// ---- the dither ------------------------------------------------------------
typedef struct {
    int depth;              // slots per scanned frame (-d)
    int lut_cap;            // the cap the library's table was built with (-b)
    int top;                // the most slots that table can ask for
    uint8_t send[65];       // the byte that lands on exactly n slots
    float tone[256];        // (v/255)^gamma, as the library computes it
    float ideal[256];       // slots wanted for each byte at the live cap
    int ideal_cap;          // the cap ideal[] was built for
    float *acc;             // one running fraction per LED colour
    int on;                 // TEMPORAL_DITHER
    float min_frac;         // DITHER_MIN
} dither_t;

static uint32_t hash32(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352dU;
    x ^= x >> 15; x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

static void dither_init(dither_t *d, const scene_info *scene, size_t px) {
    d->depth = scene->bit_depth;
    d->lut_cap = scene->brightness;
    d->on = env_int("TEMPORAL_DITHER", 1) ? 1 : 0;
    double mf = env_double("DITHER_MIN", 0.2);
    if (mf < 0.0) mf = 0.0;
    if (mf > 0.5) mf = 0.5;
    d->min_frac = (float)mf;

    // The library's own arithmetic (tone_map_rgb_bits, byte_to_bcm64), so
    // that send[n] lands on n slots exactly: tone = (v/255)^gamma, scaled by
    // the cap and truncated to a byte, and the byte rounded to slots. The
    // byte sent for n is the middle of n's run, so a nudge of one either way
    // (the library's spatial dither, if it is ever turned on) stays on n.
    int first[65], last[65];
    for (int n = 0; n <= 64; n++) { first[n] = -1; last[n] = -1; }
    for (int v = 0; v < 256; v++) {
        const float tone = powf((float)v / 255.0f, scene->gamma);
        d->tone[v] = tone;
        const float scaled = tone * (float)d->lut_cap;
        const uint8_t byte = (uint8_t)(scaled > 255.0f ? 255.0f : scaled);
        int n = (int)(((uint32_t)byte * (uint32_t)d->depth + 127u) / 255u);
        if (n > d->depth) n = d->depth;
        if (first[n] < 0) first[n] = v;
        last[n] = v;
    }
    d->top = 0;
    for (int n = 0; n <= d->depth && n <= 64; n++) {
        if (first[n] >= 0) {
            d->send[n] = (uint8_t)((first[n] + last[n]) / 2);
            d->top = n;
        } else {
            d->send[n] = (n > 0) ? d->send[n - 1] : 0;
        }
    }
    d->send[0] = 0;
    d->ideal_cap = -1;

    d->acc = malloc(px * 3 * sizeof(float));
    if (!d->acc) { perror("malloc"); exit(1); }
    for (size_t i = 0; i < px * 3; i++)
        d->acc[i] = (float)(hash32((uint32_t)i + 1u) >> 8) / 16777216.0f;
}

// The slots each byte asks for at the live cap: the light the brain meant,
// scaled, before any rounding.
static void dither_tables(dither_t *d, int cap) {
    if (cap == d->ideal_cap) return;
    for (int v = 0; v < 256; v++)
        d->ideal[v] = d->tone[v] * (float)cap / 255.0f * (float)d->depth;
    d->ideal_cap = cap;
}

static void dither_frame(dither_t *d, const uint8_t *rgb, uint8_t *staged,
                         int stride, size_t px) {
    const float lo = d->min_frac, hi = 1.0f - d->min_frac;
    for (size_t i = 0; i < px; i++) {
        for (int c = 0; c < 3; c++) {
            const uint8_t v = rgb[i * 3 + c];
            uint8_t out = 0;
            if (v != 0) {
                const float want = d->ideal[v];
                int n = (int)want;
                if (!d->on) {
                    n = (int)(want + 0.5f);
                } else {
                    const float frac = want - (float)n;
                    if (frac > hi) {
                        n += 1;
                    } else if (frac >= lo) {
                        float *a = &d->acc[i * 3 + c];
                        float s = *a + frac;
                        if (s >= 1.0f) { n += 1; s -= 1.0f; }
                        *a = s;
                    }
                }
                if (n > d->top) n = d->top;
                out = d->send[n];
            }
            staged[i * (size_t)stride + c] = out;
        }
        if (stride == 4) staged[i * 4 + 3] = 255;
    }
}

// ---- the reader: frames off the pipe into the held frame -------------------
static void *frame_reader(void *arg) {
    scene_info *scene = (scene_info *)arg;
    const size_t frame_bytes = (size_t)scene->width * scene->height * 3;
    uint8_t *rgb = calloc(1, frame_bytes);
    if (!rgb) { perror("calloc"); exit(1); }

    const char *path = fifo_path();
    mkfifo(path, 0666); // no-op if it already exists
    double kept_at = 0.0;

    for (;;) {
        int fd = open(path, O_RDONLY); // blocks until a writer connects
        if (fd < 0) { perror("open fifo"); sleep(1); continue; }

        // Hold the pipe and read frame after frame. Re-opening per frame cost
        // a syscall pair per frame and lost every frame written while we were
        // between opens.
        for (;;) {
            // Scan for the header's magic a byte at a time, so a reader that
            // starts mid-frame, or a pipe that kept half a frame across a
            // restart, lines up on the next frame instead of showing every
            // frame after it shifted.
            size_t got = 0;
            int eof = 0;
            {
                uint8_t win[4] = {0, 0, 0, 0};
                size_t have = 0;
                for (;;) {
                    uint8_t c;
                    ssize_t n = read(fd, &c, 1);
                    if (n == 0) { eof = 1; break; }
                    if (n < 0) { if (errno == EINTR) continue; eof = 1; break; }
                    if (have < 4) { win[have++] = c; }
                    else { win[0] = win[1]; win[1] = win[2]; win[2] = win[3]; win[3] = c; }
                    if (have == 4 && win[0] == 'T' && win[1] == 'S' && win[2] == 'R' && win[3] == 'A') break;
                }
                if (!eof) {
                    uint8_t rest[4];
                    size_t r = 0;
                    while (r < 4) {
                        ssize_t n = read(fd, rest + r, 4 - r);
                        if (n > 0) { r += (size_t)n; continue; }
                        if (n < 0 && errno == EINTR) continue;
                        eof = 1; break;
                    }
                    if (!eof && rest[0] >= 1 && rest[0] <= 254
                            && rest[0] != atomic_load(&live_cap)) {
                        // the cap, live: the dither scales the next map by it
                        atomic_store(&live_cap, rest[0]);
                        fprintf(stderr, "art_display: brightness %d\n", rest[0]);
                    }
                    if (!eof && rest[1] <= 100) {
                        // the library's spatial dither, tenths; its mapper
                        // reads this on every map (pixels.c)
                        float want = (float)rest[1] / 10.0f;
                        if (want != scene->dither) {
                            scene->dither = want;
                            fprintf(stderr, "art_display: dither %.1f\n", (double)want);
                        }
                    }
                }
            }
            while (!eof && got < frame_bytes) {
                ssize_t n = read(fd, rgb + got, frame_bytes - got);
                if (n > 0)  { got += (size_t)n; continue; }
                if (n == 0) { eof = 1; break; }        // writer closed
                if (errno == EINTR) continue;
                eof = 1;
                break;
            }
            if (eof || got != frame_bytes) break;      // the writer is gone

            pthread_mutex_lock(&held_lock);
            memcpy(held_rgb, rgb, frame_bytes);
            held_seq++;
            pthread_mutex_unlock(&held_lock);

            const double t = now_seconds();
            if (t - kept_at >= 1.0) {
                // written whole under a temporary name, so a relaunch that
                // lands mid-write finds the previous frame, not half of one
                char tmp[512];
                snprintf(tmp, sizeof tmp, "%s.tmp", last_frame_path());
                FILE *fh = fopen(tmp, "wb");
                if (fh) {
                    if (fwrite(rgb, 1, frame_bytes, fh) == frame_bytes && fclose(fh) == 0)
                        rename(tmp, last_frame_path());
                    else
                        unlink(tmp);
                }
                kept_at = t;
            }
        }
        close(fd);
    }
    return NULL;
}

// ---- the pacer: the held frame onto the panel, once per scanned frame ------
static void *pacer(void *arg) {
    scene_info *scene = (scene_info *)arg;
    const size_t px = (size_t)scene->width * scene->height;
    const size_t frame_bytes = px * 3;
    uint8_t *local  = calloc(1, frame_bytes);
    uint8_t *staged = calloc(1, mapper_bytes(scene));
    if (!local || !staged) { perror("calloc"); exit(1); }

    dither_t d;
    dither_init(&d, scene, px);
    fprintf(stderr, "art_display: %d slots, table cap %d (top %d), dither %s, "
                    "min fraction %.2f, cap %d\n",
            d.depth, d.lut_cap, d.top, d.on ? "on" : "off",
            (double)d.min_frac, atomic_load(&live_cap));

    const double start = now_seconds();
    double report_at = start + 10.0;
    uint64_t maps = 0, frames_in = 0, last_seq = 0;
    int timed = 0;                     // the count never moved: 60 Hz timer
    for (;;) {
        pthread_mutex_lock(&held_lock);
        memcpy(local, held_rgb, frame_bytes);
        const uint64_t seq = held_seq;
        pthread_mutex_unlock(&held_lock);
        if (seq != last_seq) { frames_in += seq - last_seq; last_seq = seq; }

        dither_tables(&d, atomic_load(&live_cap));
        dither_frame(&d, local, staged, scene->stride, px);
        scene->bcm_mapper(scene, staged);        // writes the free buffer, flips
        maps++;

        if (timed) {
            usleep(1000000 / 60);
        } else {
            // the count read after the flip: when it moves, a scan has ended
            // since, the loop has re-read the pointer, and the buffer it
            // left is free to write
            const uint64_t before = hub75_frames_scanned;
            const double t0 = now_seconds();
            while (hub75_frames_scanned == before) {
                usleep(150);
                if (now_seconds() - t0 > 0.5) {
                    if (now_seconds() - start > 5.0) {
                        fprintf(stderr, "art_display: the scan loop is not counting "
                                        "swaps (pi/hub75-swap-counter.py not applied?); "
                                        "mapping on a 60 Hz timer\n");
                        timed = 1;
                    }
                    break;
                }
            }
        }

        const double t = now_seconds();
        if (t > report_at) {
            fprintf(stderr, "art_display: %.0f maps/s, %llu frames in, cap %d, dither %s\n",
                    (double)maps / 10.0, (unsigned long long)frames_in,
                    atomic_load(&live_cap), d.on ? "on" : "off");
            maps = 0;
            frames_in = 0;
            report_at = t + 10.0;
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    scene_info *scene = default_scene(argc, argv);
    if (!scene) { fprintf(stderr, "failed to init scene\n"); return 1; }

    // Brightness comes from the bit planes, not from the library's jitter of
    // the output-enable pin. The bottom row's ghost (a scatter of the
    // content's own colour on a row that is black) needs two things gone:
    // the row address changing with output on, which the library patch in
    // pi/hub75-address-guard.py blanks, and the jitter, which puts output
    // back on at random around that change. With jitter on the ghost comes
    // back even with the guard; with it off and the guard in, it is gone.
    scene->jitter_brightness = false;

    int cap = env_int("PANEL_CAP", 254);
    if (cap < 1) cap = 1;
    if (cap > 254) cap = 254;
    atomic_store(&live_cap, cap);

    const size_t frame_bytes = (size_t)scene->width * scene->height * 3;
    held_rgb = calloc(1, frame_bytes);    // black until the first frame
    if (!held_rgb) { perror("calloc"); return 1; }
    {
        // the frame the last run kept, if it is this wall's size
        FILE *fh = fopen(last_frame_path(), "rb");
        if (fh) {
            size_t got = fread(held_rgb, 1, frame_bytes, fh);
            int more = fgetc(fh) != EOF;
            fclose(fh);
            if (got == frame_bytes && !more) {
                held_seq = 1;
                fprintf(stderr, "art_display: showing the frame kept at %s\n", last_frame_path());
            } else {
                memset(held_rgb, 0, frame_bytes);
            }
        }
    }

    pthread_t pt, rt;
    if (pthread_create(&pt, NULL, pacer, scene) != 0) {
        perror("pthread_create pacer");
        return 1;
    }
    if (pthread_create(&rt, NULL, frame_reader, scene) != 0) {
        perror("pthread_create reader");
        return 1;
    }

    fprintf(stderr, "art_display: %dx%d, fifo=%s\n",
            scene->width, scene->height, fifo_path());
    render_forever(scene);
    return 0;
}
