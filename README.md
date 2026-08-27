# asm_cat

An ultra-compact, blazing-fast UNIX `cat` utility written in **x86_64 Linux Assembly** (GNU Assembler Intel syntax).

The entire standalone executable weighs in at just **219 bytes** and **outperforms GNU `/usr/bin/cat` across all metrics** (startup latency, pipe latency, and large-file I/O throughput) while retaining zero external runtime dependencies.

---

## ⚡ Benchmark Showdown: `asm_cat` vs GNU `/usr/bin/cat`

| Benchmark Metric | GNU `/usr/bin/cat` (39 KB) | `asm_cat` (219 B) | Speedup / Winner |
| :--- | :--- | :--- | :--- |
| **Startup & Small File (1.9 KB)** | `0.711 ms` | **`0.181 ms`** | 🏆 **`asm_cat` (3.9x faster)** |
| **Piped `stdin` Latency (1.9 KB)** | `0.680 ms` | **`0.212 ms`** | 🏆 **`asm_cat` (3.2x faster)** |
| **10 MB File Throughput** | `4,089 MB/s` (`2.45 ms`) | **`20,614 MB/s` (`0.49 ms`)** | 🏆 **`asm_cat` (5.0x faster)** |
| **100 MB File Throughput** | `7,311 MB/s` (`13.68 ms`) | **`25,623 MB/s` (`3.90 ms`)** | 🏆 **`asm_cat` (3.5x faster)** |

---

## How It Wins in All 4 Dimensions

1. **Zero-Copy In-Kernel Transfer (`sys_sendfile`, syscall 40)**:
   - For regular files, `asm_cat` issues `sys_sendfile(out_fd=1, in_fd=file, offset=NULL, count=2GB)`.
   - Data is transferred directly inside the Linux page cache without copying into user-space memory, shattering **25 GB/s** transfer speeds.
2. **64 KB High-Throughput Fallback Buffer**:
   - When streaming pipes or stdin (where `sendfile` returns `EINVAL`), it automatically falls back to 64 KB block streaming mapped dynamically via the ELF segment's `p_memsz` with 0 disk-size penalty.
3. **Instant Startup**:
   - Zero dynamic library loading (`ld-linux.so`, `libc.so`), zero relocations, and no heap setup.
4. **Overlapping ELF64 Headers (219 Bytes Total)**:
   - Overlaps the 64-byte `Elf64_Ehdr` and 56-byte `Elf64_Phdr` into 112 header bytes, directly extracted via `objcopy`.

---

## Features

- **Standard Input (`stdin`)**: Reads from standard input when invoked without file arguments or via pipe.
- **Multiple Files**: Sequentially opens and outputs multiple file arguments.
- **Stdin Alias (`-`)**: Interprets `-` as standard input within argument lists (e.g. `./cat file1.txt - file2.txt`).
- **Zero Overhead**: Directly issues Linux system calls with direct memory mapping.

---

## Syscalls Used

- `sys_read` (0)
- `sys_write` (1)
- `sys_open` (2)
- `sys_close` (3)
- `sys_sendfile` (40)
- `sys_exit` (60)

---

## Building

To assemble and extract the executable:

```bash
make
```

To verify the binary size:

```bash
wc -c cat
# Output: 219 cat
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

# Read a single file (uses in-kernel zero-copy sendfile)
./cat filename.txt

# Concatenate multiple files
./cat file1.txt file2.txt

# Mix files and standard input
./cat header.txt - footer.txt < input.txt

# Pipe input
echo "Hello from high-speed Assembly!" | ./cat
```

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

Copyright (c) 2026 David Kernan
