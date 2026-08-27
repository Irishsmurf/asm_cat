# asm_cat

[![CI](https://github.com/Irishsmurf/asm_cat/actions/workflows/ci.yml/badge.svg)](https://github.com/Irishsmurf/asm_cat/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Irishsmurf/asm_cat?color=blue)](https://github.com/Irishsmurf/asm_cat/releases/latest)
[![Binary Size](https://img.shields.io/badge/binary%20size-495%20bytes-brightgreen)](https://github.com/Irishsmurf/asm_cat)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An ultra-compact, safe, and blazing-fast UNIX `cat` utility written in **x86_64 Linux Assembly** (GNU Assembler Intel syntax).

The entire standalone executable weighs in at just **495 bytes** while providing **circular read protection**, **stderr diagnostics**, **POSIX exit codes**, and **beating GNU `/usr/bin/cat` across all 4 performance metrics** (3x–4x faster).

---

## ⚡ Benchmark Showdown: `asm_cat` vs GNU `/usr/bin/cat`

| Benchmark Metric | GNU `/usr/bin/cat` (39 KB) | `asm_cat` (495 B) | Speedup / Winner |
| :--- | :--- | :--- | :--- |
| **Startup & Small File (1.9 KB)** | `0.583 ms` | **`0.183 ms`** | 🏆 **`asm_cat` (3.2x faster)** |
| **Piped `stdin` Latency (1.9 KB)** | `0.647 ms` | **`0.204 ms`** | 🏆 **`asm_cat` (3.2x faster)** |
| **10 MB File Throughput** | `5,241 MB/s` (`1.9 ms`) | **`20,753 MB/s` (`0.48 ms`)** | 🏆 **`asm_cat` (4.0x faster)** |
| **100 MB File Throughput** | `8,406 MB/s` (`11.9 ms`) | **`23,625 MB/s` (`4.23 ms`)** | 🏆 **`asm_cat` (2.8x faster)** |

---

## 🛡️ Enterprise Robustness & Safety Features

1. **Dynamic Filename & Error Diagnostics**:
   - Computes string lengths dynamically and prints exact file paths on `stderr`:
     ```text
     cat: /path/to/missing.txt: No such file or directory
     cat: /root/secret: Permission denied
     cat: /tmp: Is a directory
     ```

2. **Circular Read / Self-Append Protection**:
   - Uses `sys_fstat` (syscall 5) to check `st_dev` and `st_ino` on `stdout` vs every input file.
   - If attempting `cat file.txt >> file.txt`, safely aborts with `cat: file.txt: input file is output file` and exit code `1`.

3. **POSIX End-of-Options Delimiter (`--`)**:
   - Correctly parses `--` so files starting with a dash (e.g. `cat -- -dashed-name.txt`) are handled without collision.

4. **Signal Resilience (`EINTR`) & Partial-Write Loop**:
   - Automatically retries system calls on `-EINTR` signals (such as terminal resizing).
   - Loops on partial writes to guarantee full data delivery over saturated pipes or network sockets.

5. **Special `/proc` & `/sys` Dynamic Streaming**:
   - Seamlessly streams 0-sized virtual kernel pseudo-files until true EOF.

6. **Zero-Copy In-Kernel Splicing (`sys_sendfile`, syscall 40)**:
   - Transfers regular files directly within the Linux page cache at **>20 GB/s**.

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

## Building & Testing

To assemble and build:

```bash
make
```

To run the automated test suite (functional verification & performance regression checks):

```bash
make test
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
