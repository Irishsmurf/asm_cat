AS = as
LD = ld
ASFLAGS =
LDFLAGS = -s -N -O1 --build-id=none --no-eh-frame-hdr

TARGET = cat
SRCS = cat.s
OBJS = cat.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $(OBJS)
	strip -s -R .comment -R .note.gnu.build-id -R .note.gnu.property -R .note.gnu.gold-version $@

%.o: %.s
	$(AS) $(ASFLAGS) -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
