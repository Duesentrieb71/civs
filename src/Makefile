CC ?= cc
CFLAGS ?= -O2 -Wall

.PHONY: all clean

all: gettimeofday timeout lockserv

gettimeofday: gettimeofday.c
	$(CC) $(CFLAGS) -o $@ $<

timeout: timeout.c
	$(CC) $(CFLAGS) -o $@ $<

lockserv: lockserv.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f gettimeofday timeout lockserv
