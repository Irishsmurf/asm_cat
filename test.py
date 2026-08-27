#!/usr/bin/env python3
"""
Automated Test & Performance Regression Suite for asm_cat.

Tests:
1. Functional Correctness (stdin, files, multi-file, '-' alias, missing file error, circular read protection, directories, /proc & /sys pseudo-files).
2. Performance Benchmark Assertion: Ensures asm_cat beats GNU /usr/bin/cat across all 4 metrics.
"""

import os
import sys
import time
import tempfile
import statistics
import subprocess

ASM_CAT = os.path.abspath("./cat")
GNU_CAT = "/usr/bin/cat"

RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
BOLD = "\033[1m"
RESET = "\033[0m"


def run_cmd(cmd, input_data=None):
    return subprocess.run(
        cmd,
        input=input_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )


def test_functional():
    print(f"{BOLD}=== 1. FUNCTIONAL CORRECTNESS TESTS ==={RESET}")

    # Test 1: Piped stdin
    payload = b"Hello world from asm_cat test suite!\n"
    res = run_cmd([ASM_CAT], input_data=payload)
    assert res.returncode == 0, f"Stdin failed returncode: {res.returncode}"
    assert res.stdout == payload, "Stdin output mismatch"
    print(f"  {GREEN}[PASS]{RESET} Piped stdin streaming")

    # Test 2: File reading
    with tempfile.NamedTemporaryFile(delete=False) as f1, tempfile.NamedTemporaryFile(delete=False) as f2:
        f1.write(b"Line 1 from file1\n")
        f2.write(b"Line 2 from file2\n")
        f1_path, f2_path = f1.name, f2.name

    try:
        # Single file
        res = run_cmd([ASM_CAT, f1_path])
        assert res.returncode == 0 and res.stdout == b"Line 1 from file1\n"
        print(f"  {GREEN}[PASS]{RESET} Single file reading")

        # Multi-file + stdin alias ('-')
        res = run_cmd([ASM_CAT, f1_path, "-", f2_path], input_data=b"Middle stdin line\n")
        expected = b"Line 1 from file1\nMiddle stdin line\nLine 2 from file2\n"
        assert res.returncode == 0 and res.stdout == expected, "Multi-file/stdin output mismatch"
        print(f"  {GREEN}[PASS]{RESET} Multi-file concatenation with '-' stdin alias")

        # Missing file error handling
        res = run_cmd([ASM_CAT, "/tmp/definitely_non_existent_asm_cat_file.xyz"])
        assert res.returncode == 1, f"Expected returncode 1, got {res.returncode}"
        assert b"cat: cannot open file\n" in res.stderr
        print(f"  {GREEN}[PASS]{RESET} Missing file diagnostics (stderr & exit code 1)")

        # Directory detection
        res = run_cmd([ASM_CAT, "/tmp"])
        assert res.returncode == 1, f"Expected returncode 1 for directory, got {res.returncode}"
        assert b"cat: Is a directory\n" in res.stderr
        print(f"  {GREEN}[PASS]{RESET} Directory input detection ('cat: Is a directory')")

        # Special /proc and /sys pseudo-files
        if os.path.exists("/proc/cpuinfo"):
            res_asm = run_cmd([ASM_CAT, "/proc/cpuinfo"])
            assert res_asm.returncode == 0
            assert b"processor" in res_asm.stdout and b"vendor_id" in res_asm.stdout, "/proc/cpuinfo contents missing"
            assert len(res_asm.stdout) > 1000
            print(f"  {GREEN}[PASS]{RESET} Special pseudo-file reading (/proc/cpuinfo)")

        if os.path.exists("/sys/devices/system/cpu/online"):
            res_gnu = run_cmd([GNU_CAT, "/sys/devices/system/cpu/online"])
            res_asm = run_cmd([ASM_CAT, "/sys/devices/system/cpu/online"])
            assert res_asm.returncode == 0
            assert res_asm.stdout == res_gnu.stdout, "/sys pseudo-file output mismatch"
            print(f"  {GREEN}[PASS]{RESET} Special pseudo-file reading (/sys/...)")

        # Circular read protection
        circ_file = tempfile.NamedTemporaryFile(delete=False)
        circ_file.write(b"Initial content\n")
        circ_file.close()

        with open(circ_file.name, "ab") as f_out:
            res = subprocess.run([ASM_CAT, circ_file.name], stdout=f_out, stderr=subprocess.PIPE)
        assert res.returncode == 1, "Circular read should exit with code 1"
        assert b"cat: input file is output file\n" in res.stderr
        with open(circ_file.name, "rb") as f_check:
            assert f_check.read() == b"Initial content\n", "File should not have grown"
        os.remove(circ_file.name)
        print(f"  {GREEN}[PASS]{RESET} Circular read / self-append protection")

    finally:
        if os.path.exists(f1_path): os.remove(f1_path)
        if os.path.exists(f2_path): os.remove(f2_path)

    print()


def bench(cmd, iterations, input_data=None):
    times = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        subprocess.run(cmd, input=input_data, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000) # ms
    return statistics.mean(times)


def test_performance():
    print(f"{BOLD}=== 2. PERFORMANCE REGRESSION SUITE (vs GNU /usr/bin/cat) ==={RESET}")

    # Generate temporary payloads
    with tempfile.NamedTemporaryFile(delete=False) as f_small, \
         tempfile.NamedTemporaryFile(delete=False) as f_10mb, \
         tempfile.NamedTemporaryFile(delete=False) as f_100mb:
        f_small.write(b"Performance test payload small file line.\n" * 50)
        f_10mb.write(os.urandom(10 * 1024 * 1024))
        f_100mb.write(os.urandom(100 * 1024 * 1024))
        small_path = f_small.name
        med_path = f_10mb.name
        large_path = f_100mb.name

    with open(small_path, "rb") as f:
        small_data = f.read()

    try:
        # 1. Startup Latency
        t_gnu_s = bench([GNU_CAT, small_path], 200)
        t_asm_s = bench([ASM_CAT, small_path], 200)
        speedup_s = t_gnu_s / t_asm_s
        print(f"  1. Startup / Small File:  GNU = {t_gnu_s:.3f}ms | asm_cat = {t_asm_s:.3f}ms ({speedup_s:.2f}x faster)")
        assert t_asm_s < t_gnu_s, f"REGRESSION: asm_cat ({t_asm_s:.3f}ms) slower than GNU cat ({t_gnu_s:.3f}ms)"
        print(f"     {GREEN}[PASS]{RESET} asm_cat won startup latency")

        # 2. Piped Stdin Latency
        t_gnu_p = bench([GNU_CAT], 200, input_data=small_data)
        t_asm_p = bench([ASM_CAT], 200, input_data=small_data)
        speedup_p = t_gnu_p / t_asm_p
        print(f"  2. Piped Stdin Latency:   GNU = {t_gnu_p:.3f}ms | asm_cat = {t_asm_p:.3f}ms ({speedup_p:.2f}x faster)")
        assert t_asm_p < t_gnu_p, f"REGRESSION: asm_cat ({t_asm_p:.3f}ms) slower than GNU cat ({t_gnu_p:.3f}ms)"
        print(f"     {GREEN}[PASS]{RESET} asm_cat won pipe latency")

        # 3. 10 MB File Throughput
        t_gnu_m = bench([GNU_CAT, med_path], 20)
        t_asm_m = bench([ASM_CAT, med_path], 20)
        mbps_gnu_m = 10 / (t_gnu_m / 1000)
        mbps_asm_m = 10 / (t_asm_m / 1000)
        print(f"  3. 10 MB Throughput:      GNU = {mbps_gnu_m:.1f} MB/s | asm_cat = {mbps_asm_m:.1f} MB/s ({t_gnu_m/t_asm_m:.2f}x faster)")
        assert t_asm_m < t_gnu_m, f"REGRESSION: asm_cat ({mbps_asm_m:.1f} MB/s) slower than GNU cat ({mbps_gnu_m:.1f} MB/s)"
        print(f"     {GREEN}[PASS]{RESET} asm_cat won 10 MB streaming")

        # 4. 100 MB File Throughput
        t_gnu_l = bench([GNU_CAT, large_path], 10)
        t_asm_l = bench([ASM_CAT, large_path], 10)
        mbps_gnu_l = 100 / (t_gnu_l / 1000)
        mbps_asm_l = 100 / (t_asm_l / 1000)
        print(f"  4. 100 MB Throughput:     GNU = {mbps_gnu_l:.1f} MB/s | asm_cat = {mbps_asm_l:.1f} MB/s ({t_gnu_l/t_asm_l:.2f}x faster)")
        assert t_asm_l < t_gnu_l, f"REGRESSION: asm_cat ({mbps_asm_l:.1f} MB/s) slower than GNU cat ({mbps_gnu_l:.1f} MB/s)"
        print(f"     {GREEN}[PASS]{RESET} asm_cat won 100 MB streaming")

    finally:
        if os.path.exists(small_path): os.remove(small_path)
        if os.path.exists(med_path): os.remove(med_path)
        if os.path.exists(large_path): os.remove(large_path)

    # 3. Binary Size Assertion: Ensure binary stays ultra-compact (< 512 bytes)
    print(f"\n{BOLD}=== 3. BINARY SIZE REGRESSION SUITE ==={RESET}")
    bin_size = os.path.getsize(ASM_CAT)
    print(f"  Current asm_cat size: {bin_size} bytes (Maximum allowed: 512 bytes)")
    assert bin_size < 512, f"SIZE REGRESSION: Binary size {bin_size} exceeds 512 bytes limit!"
    print(f"  {GREEN}[PASS]{RESET} Binary size within ultra-compact limit ({bin_size} B / <512 B)")

    print(f"\n{BOLD}{GREEN}ALL FUNCTIONAL, PERFORMANCE, AND SIZE ASSERTIONS PASSED!{RESET}\n")


if __name__ == "__main__":
    if not os.path.exists(ASM_CAT):
        print(f"{RED}Error: Binary '{ASM_CAT}' not found. Run `make` first.{RESET}")
        sys.exit(1)
    test_functional()
    test_performance()
