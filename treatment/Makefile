CC      ?= gcc
CFLAGS  ?= -O2 -Wall
LDLIBS  := -luring -lpthread

TARGET  := accept-treat
SRC     := accept-treat.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)

clean:
	rm -f $(TARGET)
