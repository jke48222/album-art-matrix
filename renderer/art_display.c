// art_display — push frames from a named pipe onto the HUB75 wall.
// Built against bitslip6/rpi-gpu-hub75-matrix (pi/bootstrap.sh installs it).
//
// Protocol: a writer opens the FIFO and streams raw RGB888 frames back to
// back (width*height*3 bytes each). We hold the read end open and re-open only
// on EOF, so the brain can come and go while the wall keeps showing the last
// frame it sent.
//
// Threading: render_forever() owns the BCM refresh on the isolated core; we
// call scene->bcm_mapper() from the reader thread when a full frame arrives.
//
// RATE LIMIT, and why it exists. bcm_mapper writes the same bit-plane buffer
// the refresh thread is scanning, so every map is a window in which the panel
// can show a partly-built frame. That was tolerable when frames arrived 20
// times a second and became visible black flashing at 120, because the window
// is a fixed cost and raising the rate raises how much of the time you are
// inside one. Until the library exposes a real double buffer with an atomic
// swap, the honest fix is to map no more often than MAX_MAP_HZ and drop the
// frames in between: a dropped frame is invisible, a torn one is not.
//
// If the library grows an explicit swap API, delete the limiter and use it —
// check example.c in the library repo when it updates.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <time.h>
#include <sys/stat.h>

#include <rpihub75/rpihub75.h>
#include <rpihub75/util.h>   // default_scene() lives here as of lib v0.2
#include <rpihub75/pixels.h>
#include <rpihub75/gpu.h>

// Frames mapped per second. Above this the tearing window starts to dominate.
// Overridable so the ceiling can be found on real hardware instead of guessed:
//   MAX_MAP_HZ=90 ./art_display
static double max_map_hz(void) {
    const char *v = getenv("MAX_MAP_HZ");
    if (v) { double d = atof(v); if (d > 0) return d; }
    return 60.0;
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

static void map_frame(scene_info *scene, const uint8_t *rgb,
                      uint8_t *staged, size_t frame_bytes);

static void *frame_reader(void *arg) {
    scene_info *scene = (scene_info *)arg;
    const size_t frame_bytes = (size_t)scene->width * scene->height * 3;
    const size_t stage_bytes = (size_t)scene->width * scene->height * scene->stride;
    uint8_t *rgb    = calloc(1, frame_bytes);
    uint8_t *staged = calloc(1, stage_bytes);
    if (!rgb || !staged) { perror("calloc"); exit(1); }

    const char *path = fifo_path();
    mkfifo(path, 0666); // no-op if it already exists

    const double min_gap = 1.0 / max_map_hz();
    double last_map = 0.0;
    long dropped = 0, mapped = 0;
    double report_at = now_seconds() + 10.0;

    for (;;) {
        int fd = open(path, O_RDONLY); // blocks until a writer connects
        if (fd < 0) { perror("open fifo"); sleep(1); continue; }

        // Hold the pipe and read frame after frame. Re-opening per frame cost
        // a syscall pair per frame and lost every frame written while we were
        // between opens.
        for (;;) {
            size_t got = 0;
            int eof = 0;
            while (got < frame_bytes) {
                ssize_t n = read(fd, rgb + got, frame_bytes - got);
                if (n > 0)  { got += (size_t)n; continue; }
                if (n == 0) { eof = 1; break; }        // writer closed
                if (errno == EINTR) continue;
                eof = 1;
                break;
            }
            if (eof) break;
            if (got != frame_bytes) break;             // partial — resync

            double t = now_seconds();
            if (t - last_map < min_gap) {              // too soon to map safely
                dropped++;
                continue;
            }
            last_map = t;
            mapped++;

            if (t > report_at) {
                fprintf(stderr, "art_display: %ld mapped, %ld dropped in 10s "
                                "(cap %.0f Hz)\n", mapped, dropped, max_map_hz());
                mapped = dropped = 0;
                report_at = t + 10.0;
            }

            map_frame(scene, rgb, staged, frame_bytes);
        }
        close(fd);
    }
    return NULL;
}

static void map_frame(scene_info *scene, const uint8_t *rgb,
                      uint8_t *staged, size_t frame_bytes) {
    {
        if (scene->stride == 3) {
            memcpy(staged, rgb, frame_bytes);
        } else {                               // expand RGB into 4-byte stride
            size_t px = (size_t)scene->width * scene->height;
            for (size_t i = 0; i < px; i++) {
                staged[i*4+0] = rgb[i*3+0];
                staged[i*4+1] = rgb[i*3+1];
                staged[i*4+2] = rgb[i*3+2];
                staged[i*4+3] = 255;
            }
        }
        scene->bcm_mapper(scene, staged);
    }
}

int main(int argc, char **argv) {
    scene_info *scene = default_scene(argc, argv);
    if (!scene) { fprintf(stderr, "failed to init scene\n"); return 1; }

    // Defined black before the first frame arrives.
    uint8_t *black = calloc(1, (size_t)scene->width * scene->height * scene->stride);
    if (black) { scene->bcm_mapper(scene, black); free(black); }

    pthread_t tid;
    if (pthread_create(&tid, NULL, frame_reader, scene) != 0) {
        perror("pthread_create");
        return 1;
    }

    fprintf(stderr, "art_display: %dx%d, fifo=%s\n",
            scene->width, scene->height, fifo_path());
    render_forever(scene);
    return 0;
}
