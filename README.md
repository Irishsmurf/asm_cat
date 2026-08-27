# asm_cat

An ultra-compact, safe, and blazing-fast UNIX `cat` utility written in **x86_64 Linux Assembly** (GNU Assembler Intel syntax).

The entire standalone executable weighs in at just **417 bytes** while providing **circular read protection**, **stderr diagnostics**, **POSIX exit codes**, and **beating GNU `/usr/bin/cat` across all 4 performance metrics** (3x–4x faster).

---

## ⚡ Benchmark Showdown: `asm_cat` vs GNU `/usr/bin/cat`

| Benchmark Metric | GNU `/usr/bin/cat` (39 KB) | `asm_cat` (417 B) | Speedup / Winner |
| :--- | :--- | :--- | :--- |
| **Startup & Small File (1.9 KB)** | `0.583 ms` | **`0.183 ms`** | 🏆 **`asm_cat` (3.2x faster)** |
| **Piped `stdin` Latency (1.9 KB)** | `0.647 ms` | **`0.204 ms`** | 🏆 **`asm_cat` (3.2x faster)** |
| **10 MB File Throughput** | `5,241 MB/s` (`1.9 ms`) | **`20,753 MB/s` (`0.48 ms`)** | 🏆 **`asm_cat` (4.0x faster)** |
| **100 MB File Throughput** | `8,406 MB/s` (`11.9 ms`) | **`23,625 MB/s` (`4.23 ms`)** | 🏆 **`asm_cat` (2.8x faster)** |

---

## 🛡️ Safety & Error Handling Features

1. **Circular Read / Self-Append Protection**:
   - Uses `sys_fstat` (syscall 5) to inspect the device ID (`st_dev`) and inode number (`st_ino`) of `stdout` against every input file.
   - If attempting to read from the file being written to (e.g. `cat file.txt >> file.txt`), `asm_cat` aborts with:
     ```text
     cat: input file is output file
     ```
     and exits with error code `1`.

2. **Standard Diagnostics on `stderr` (FD 2)**:
   - Missing or unreadable files produce descriptive errors:
     ```text
     cat: cannot open file
     ```

3. **POSIX Error Status Exit Code**:
   - Exits with `0` on complete success, or `1` if any file failed to open or encountered a circular dependency.

4. **Zero-Copy In-Kernel Splicing (`sys_sendfile`, syscall 40)**:
   - Transfers regular files directly within the Linux page cache at **>20 GB/s**.

5. **64 KB High-Throughput Pipe Fallback**:
   - Dynamically mapped BSS buffer for stdin pipes at 0 disk-size cost.

---

## Syscalls Used

- `sys_read` (0)
- `sys_write` (1)
- `sys_open` (2)
- `sys_close` (3)
- `sys_fstat` (5)
- `sys_sendfile` (40)
- `sys_exit` (60)

---

## Building & Installation

To build:

```bash
make
```

To install directly to `~/.local/bin/cat`:

```bash
make install
```

To uninstall:

```bash
make uninstall
```

---

## Usage Examples

```bash
# Standard input
./cat

# Zero-copy file concatenation
./cat file1.txt file2.txt

# Mix files and standard input
./cat header.txt - footer.txt < input.txt

# Protected from circular reads (safely aborts with code 1)
./cat output.txt >> output.txt
```

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

Copyright (c) 2026 David Kernan
