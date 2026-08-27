# asm_cat

A minimal, ultra-optimized UNIX `cat` utility written in **x86_64 Linux Assembly** (GNU Assembler Intel syntax).

The entire standalone executable weighs in at just **197 bytes**, achieved through hand-crafted, overlapping ELF64 and Program Headers with zero external dependencies (no libc, no standard linker overhead).

---

## Features

- **Standard Input (`stdin`)**: Reads from standard input when invoked without file arguments or via pipe.
- **Multiple Files**: Sequentially opens and outputs multiple file arguments.
- **Stdin Alias (`-`)**: Interprets `-` as standard input within argument lists (e.g. `./cat file1.txt - file2.txt`).
- **Zero Overhead**: Directly issues Linux system calls with direct memory mapping.
- **Dynamic BSS Buffer**: Dynamically allocates a 4 KB I/O buffer past the binary's mapped image using ELF `p_memsz` expansion (0 bytes on-disk cost).

---

## Binary Layout & Size Optimizations (197 Bytes Total)

| Component | Size | Details |
| :--- | :--- | :--- |
| **ELF Header & Program Header** | **112 bytes** | Overlaps the 64-byte `Elf64_Ehdr` and 56-byte `Elf64_Phdr` (`PT_LOAD`) at offset `0x38`, sharing fields between the two headers. |
| **Machine Code (`.text`)** | **85 bytes** | Compact x86_64 instructions using short immediate pushes/pops, register exchanges, and a unified I/O loop. |
| **Total File Size** | **197 bytes** | |

---

## Syscalls Used

- `sys_read` (0)
- `sys_write` (1)
- `sys_open` (2)
- `sys_close` (3)
- `sys_exit` (60)

---

## Prerequisites

- **Operating System**: Linux (x86_64)
- **Tools**: GNU Assembler (`as`), `objcopy`, `make`

---

## Building

To assemble and extract the executable:

```bash
make
```

To verify the binary size:

```bash
wc -c cat
# Output: 197 cat
```

To clean up build artifacts:

```bash
make clean
```

---

## Usage Examples

```bash
# Read from standard input
./cat

# Read a single file
./cat filename.txt

# Concatenate multiple files
./cat file1.txt file2.txt

# Mix files and standard input
./cat header.txt - footer.txt < input.txt

# Pipe input
echo "Hello, 197-byte Assembly!" | ./cat
```
