CC = as
LD = ld
CFLAGS = 
LDFLAGS =

TARGET = cat
SRCS = cat.s
OBJS = cat.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $(OBJS)

%.o: %.s
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
