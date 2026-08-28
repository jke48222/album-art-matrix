// art_display — push frames from a named pipe onto the HUB75 wall.
// Built against bitslip6/rpi-gpu-hub75-matrix (pi/bootstrap.sh installs it).
//
// Protocol: a writer opens the FIFO, writes exactly one raw RGB888 frame
// (width*height*3 bytes), closes. Repeat per frame. We re-open on EOF, so the
// brain can come and go while the wall keeps showing the last frame.
//
// Threading: render_forever() owns the BCM refresh on the isolated core; we
// call scene->bcm_mapper() from the reader thread when a full frame arrives.
// At 9600 Hz a mid-map tear is one invisible refresh cycle. If the library
// grows an explicit double-buffer swap API, switch to it — check example.c
// in the library repo when it updates.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <sys/stat.h>

#include <rpihub75/rpihub75.h>
#include <rpihub75/util.h>   // default_scene() lives here as of lib v0.2
#include <rpihub75/pixels.h>
#include <rpihub75/gpu.h>

static const char *fifo_path(void) {
    const char *p = getenv("FRAME_FIFO");
    return p ? p : "/tmp/album-frame.fifo";
}

static void *frame_reader(void *arg) {
    scene_info *scene = (scene_info *)arg;
    const size_t frame_bytes = (size_t)scene->width * scene->height * 3;
    const size_t stage_bytes = (size_t)scene->width * scene->height * scene->stride;
    uint8_t *rgb    = calloc(1, frame_bytes);
    uint8_t *staged = calloc(1, stage_bytes);
    if (!rgb || !staged) { perror("calloc"); exit(1); }

    const char *path = fifo_path();
    mkfifo(path, 0666); // no-op if it already exists

    for (;;) {
        int fd = open(path, O_RDONLY); // blocks until a writer connects
        if (fd < 0) { perror("open fifo"); sleep(1); continue; }

        size_t got = 0;
        while (got < frame_bytes) {
            ssize_t n = read(fd, rgb + got, frame_bytes - got);
            if (n > 0)  { got += (size_t)n; continue; }
            if (n == 0) break;                 // writer closed early
            if (errno == EINTR) continue;
            break;
        }
        close(fd);
        if (got != frame_bytes) continue;      // partial frame — drop it

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
    return NULL;
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
