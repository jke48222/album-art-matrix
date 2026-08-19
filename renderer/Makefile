# Requires bitslip6/rpi-gpu-hub75-matrix installed (pi/bootstrap.sh does this).
CC ?= gcc
CFLAGS ?= -Wall -O3 -mtune=native
LDLIBS = -lrpihub75_gpu -lpthread -lm

art_display: art_display.c
	$(CC) $(CFLAGS) art_display.c -o art_display $(LDLIBS)

clean:
	rm -f art_display
.PHONY: clean
