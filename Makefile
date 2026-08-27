# ==============================================================================
# Makefile for asm_cat (Ultra-compact 197-byte UNIX 'cat' implementation)
#
# Build Strategy:
# 1. Assemble 'cat.s' using GNU Assembler (as) into an intermediate ELF object.
# 2. Extract the raw flat machine code and crafted ELF headers from the '.text'
#    section using 'objcopy -O binary -j .text'.
# 3. Mark the resulting file executable.
#
# This bypasses the standard GNU linker (ld) section padding and ELF metadata
# overhead, yielding an exact 197-byte standalone executable.
# ==============================================================================

# Toolchain definitions
AS      := as
OBJCOPY := objcopy
CHMOD   := chmod
RM      := rm -f

# Target and source file definitions
TARGET  := cat
SRCS    := cat.s
OBJS    := cat.o

# Assembler flags (no special flags needed; code uses .intel_syntax noprefix internally)
ASFLAGS :=

# Default rule: build the executable
all: $(TARGET)

# Link / extraction step:
# Extracts the raw flat binary directly from the .text section of cat.o
# which already contains the crafted ELF header, PT_LOAD program header, and machine code.
$(TARGET): $(OBJS)
	$(OBJCOPY) -O binary -j .text $< $@
	$(CHMOD) +x $@

# Assembly step:
# Compiles the assembly source file into an ELF64 object file
%.o: %.s
	$(AS) $(ASFLAGS) -o $@ $<

# Clean rule:
# Removes compiled objects and the target executable binary
clean:
	$(RM) $(OBJS) $(TARGET)

# Phony targets to prevent conflicts with files named 'all' or 'clean'
.PHONY: all clean
