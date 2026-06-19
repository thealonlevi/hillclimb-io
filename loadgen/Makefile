CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra
all: loadgen
loadgen: loadgen.c
	$(CC) $(CFLAGS) -o loadgen loadgen.c -lpthread
clean:
	rm -f loadgen
.PHONY: all clean
