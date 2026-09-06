# Requires bitslip6/rpi-gpu-hub75-matrix installed (pi/bootstrap.sh does this).
CC ?= gcc
CFLAGS ?= -Wall -O3 -mtune=native
# The library as built in the home directory, patched to hold the output off
# while each row address settles (see rpihub75.c, ADDR_GUARD_PX), ahead of the
# copy under /usr/local. Installing there needs root; this does not.
LIBHOME = $(HOME)/rpi-gpu-hub75-matrix
LDLIBS = -L$(LIBHOME) -Wl,-rpath,$(LIBHOME) -lrpihub75_gpu -lpthread -lm

art_display: art_display.c
	$(CC) $(CFLAGS) art_display.c -o art_display $(LDLIBS)

clean:
	rm -f art_display
.PHONY: clean
