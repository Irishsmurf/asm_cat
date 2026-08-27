# ==============================================================================
# Makefile for asm_cat (Ultra-compact, High-Performance UNIX 'cat' in x86_64 ASM)
# ==============================================================================

# Toolchain definitions
AS      := as
OBJCOPY := objcopy
CHMOD   := chmod
RM      := rm -f
PYTHON  := python3

# Target and source file definitions
TARGET  := cat
SRCS    := cat.s
OBJS    := cat.o

# Assembler flags
ASFLAGS :=

# Default rule: build the executable
all: $(TARGET)

# Link / extraction step:
# Extracts the raw flat binary directly from the .text section of cat.o
$(TARGET): $(OBJS)
	$(OBJCOPY) -O binary -j .text $< $@
	$(CHMOD) +x $@

# Assembly step:
%.o: %.s
	$(AS) $(ASFLAGS) -o $@ $<

# Test rule: runs functional test suite and performance assertions
test: $(TARGET)
	$(PYTHON) test.py

# Install / Uninstall rules
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

install: $(TARGET)
	mkdir -p $(BINDIR)
	cp $(TARGET) $(BINDIR)/$(TARGET)

uninstall:
	$(RM) $(BINDIR)/$(TARGET)

# Clean rule:
clean:
	$(RM) $(OBJS) $(TARGET)

.PHONY: all clean install uninstall test
