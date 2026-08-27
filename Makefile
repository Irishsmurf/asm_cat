AS = as
OBJCOPY = objcopy

TARGET = cat
SRCS = cat.s
OBJS = cat.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(OBJCOPY) -O binary -j .text $< $@
	chmod +x $@

%.o: %.s
	$(AS) -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
