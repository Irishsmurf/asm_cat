# asm_cat

A naive implementation of the UNIX `cat` utility written in **x86_64 Linux Assembly** using GNU Assembler (GAS) syntax with Intel syntax notation.

It directly interacts with Linux system calls and has zero external dependencies (no C runtime / libc required).

## Features

- **Standard Input (`stdin`)**: Reads from standard input when no file arguments are supplied.
- **Multiple Files**: Reads and concatenates multiple files passed as command-line arguments.
- **Stdin Alias (`-`)**: Supports `-` as an argument to read from `stdin` amidst other files.
- **Buffered I/O**: Performs I/O in 4 KB chunks using direct `sys_read` and `sys_write` syscalls.

## Syscalls Used

- `sys_read` (0)
- `sys_write` (1)
- `sys_open` (2)
- `sys_close` (3)
- `sys_exit` (60)

## Prerequisites

- **OS**: Linux (x86_64)
- **Assembler**: GNU Assembler (`as`)
- **Linker**: GNU Linker (`ld`)
- **Build tool**: `make`

## Building

To assemble and link the binary:

```bash
make
```

To clean up build artifacts:

```bash
make clean
```

## Usage

```bash
# Read from standard input
./cat

# Read a single file
./cat filename.txt

# Concatenate multiple files
./cat file1.txt file2.txt

# Mix files and stdin
./cat header.txt - footer.txt < input.txt

# Pipe input
echo "Hello, Assembly!" | ./cat
```
