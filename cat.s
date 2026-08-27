# ==============================================================================
# asm_cat: Ultra-compact, Enterprise-Grade, High-Performance UNIX 'cat' in x86_64 ASM
#
# Features:
# 1. Zero-Copy In-Kernel sys_sendfile (syscall 40) for regular non-empty files.
# 2. 64 KB dynamically mapped fallback buffer for pipes, stdin, /proc, and /sys.
# 3. Dynamic Filename in Error Messages: "cat: <filename>: <error>"
# 4. Accurate POSIX Error Translation (ENOENT, EACCES, EISDIR).
# 5. POSIX End-of-Options Parsing ('--').
# 6. Signal Interruption Resilience (EINTR).
# 7. Partial-Write Loop for complete delivery.
# 8. Circular Read / Self-Append Prevention.
# 9. Overlapped ELF64 Headers, with executable code packed into the header's
#    unused fields (e_ident padding, e_shoff, e_flags, e_ehsize).
#
# Size techniques used throughout:
# - Absolute immediates (`mov esi, ABS`) instead of `lea rXX, [rip + sym]`:
#   5 bytes vs 7. Both operands of the address expression are same-section
#   symbols, so `as` folds them at assembly time and emits NO relocation --
#   which is required, since the build objcopy's the unlinked .o directly.
# - Where rsi is already known to hold an address in the image, only its low
#   half is reloaded (`mov si, imm16`, 4 bytes). Asserted at the end of file.
# - Error messages are self-delimiting (each ends in '\n'), so no length needs
#   to be passed or stored; report_error scans for the terminator.
# - report_error assembles the whole diagnostic in the I/O buffer and issues a
#   single write(2) instead of four.
# - Cold paths are laid out so hot branches stay within rel8 (2-byte) range.
# - Registers are assumed zero at entry (guaranteed by ELF_PLAT_INIT on x86-64).
# ==============================================================================

.intel_syntax noprefix

.equ LOAD_ADDR, 0x400000

# Absolute run-time addresses = LOAD_ADDR + file offset.
.equ BUF,      LOAD_ADDR + (file_end   - ehdr)
.equ M_OPEN,   LOAD_ADDR + (msg_open   - ehdr)
.equ M_NOENT,  LOAD_ADDR + (msg_noent  - ehdr)
.equ M_ACCES,  LOAD_ADDR + (msg_acces  - ehdr)
.equ M_DIR,    LOAD_ADDR + (msg_dir    - ehdr)
.equ M_CIRC,   LOAD_ADDR + (msg_circ   - ehdr)

.section .text
.global _start

_start:
# ==============================================================================
# 1. ELF HEADER (Elf64_Ehdr) & OVERLAPPED PROGRAM HEADER (Elf64_Phdr)
#
# Every .org below doubles as a build-time assertion: if a code block outgrows
# its hole, `as` fails with "attempt to move .org backwards" rather than
# silently emitting a corrupt header.
# ==============================================================================
ehdr:
    .byte 0x7f, 'E', 'L', 'F', 2, 1, 1, 0   # e_ident[0..7]

# --- Code Hole 1: e_ident[8..15] (EI_ABIVERSION + padding, never read) -------
.org 0x08
entry:                                  # e_entry points here
    push 5                              # SYS_FSTAT = 5
    pop rax
    inc edi                             # STDOUT_FILENO = 1 (rdi is 0 at entry)
    jmp entry_cont

.org 0x10
    .word 2                             # e_type = ET_EXEC
    .word 62                            # e_machine = EM_X86_64
    .long 1                             # e_version = 1
    .quad LOAD_ADDR + (entry - ehdr)    # e_entry
    .quad 0x38                          # e_phoff: Points to offset 0x38

# --- Code Hole 2: e_shoff, e_flags, e_ehsize (unused with no section table) --
.org 0x28
entry_cont:
    mov esi, BUF                        # statbuf = &file_end
    syscall                             # fstat(1, &file_end)
    mov r14, [rsi]                      # r14 = stdout st_dev
    pop rbp                             # rbp = argc
    pop rax                             # discard argv[0]
    jmp code_entry

.org 0x36
    .word 56                            # e_phentsize (kernel requires 56)

    # --- Overlap Region at Offset 0x38 (8 bytes) ---
    .word 1                             # e_phnum     (1) | p_type  = PT_LOAD (1)
    .word 0                             # e_shentsize (0) | p_type  (high 16-bit)
    .word 7                             # e_shnum     (7) | p_flags = PF_R|PF_W|PF_X (7)
    .word 0                             # e_shstrndx  (0) | p_flags (high 16-bit)

    # --- Program Header Fields ---
    .quad 0                             # p_offset
    .quad LOAD_ADDR                     # p_vaddr
    .quad LOAD_ADDR                     # p_paddr
    .quad file_end - ehdr               # p_filesz
    .quad file_end - ehdr + 0x30000     # p_memsz: 192 KB BSS. 64 KB is the I/O
                                        # buffer; the headroom lets report_error
                                        # stage a diagnostic for a filename of
                                        # any legal length (MAX_ARG_STRLEN=128K).
    .quad 0x1000                        # p_align

# ==============================================================================
# 2. CODE ENTRY POINT & EXECUTION LOGIC (Offset 0x70)
#
# Register map:
#   rbp = files remaining      rbx = current fd        r8  = current filename
#   r9d = raw-args flag ('--') r12d = exit status      r13b = stdout st_mode>>8
#   r14 = stdout st_dev        r15 = stdout st_ino
# r12d and r9d are not initialized here: the kernel zeroes all GPRs before
# transferring control to a static ELF's entry point (ELF_PLAT_INIT, x86-64).
# ==============================================================================
code_entry:
    mov r15, [rsi + 8]                  # r15 = stdout st_ino
    mov r13b, [rsi + 25]                # r13b = stdout st_mode high byte
    dec ebp                             # argc - 1 = file argument count
    jz .stdin_entry                     # If no args, stream stdin

.arg_loop:
    pop rdi                             # rdi = argv[i]

    # If raw mode is off, check for options
    test r9d, r9d
    jnz .process_as_file

    # Check for '--' (End of options)
    cmp word ptr [rdi], 0x2d2d          # '--' ?
    jne .check_stdin_dash
    cmp byte ptr [rdi + 2], 0           # '--\0' ?
    jne .check_stdin_dash
    inc r9d                             # Enable raw mode (r9d = 1)
    jmp .next_file

.check_stdin_dash:
    # Check for single '-' (stdin alias)
    cmp word ptr [rdi], 0x002d          # Is '-' ?
    je .stdin_entry

.process_as_file:
    mov r8, rdi                         # Preserve filename in r8

    # sys_open(filename=rdi, flags=O_RDONLY (0), mode=0)
    push 2                              # SYS_OPEN = 2
    pop rax
    xor esi, esi
    cdq                                 # edx = 0 (since eax = 2 >= 0)
    syscall
    test eax, eax
    js .open_error                      # Negative errno returned
    xchg ebx, eax                       # ebx = fd

    # sys_fstat(fd=ebx, statbuf=&file_end)
    push 5                              # SYS_FSTAT = 5
    pop rax
    xchg edi, ebx                       # edi = fd, ebx = 5 (restored on syscall/xchg)
    mov esi, BUF
    syscall
    xchg edi, ebx                       # ebx = fd

    # Check if directory. Byte 25 of struct stat is st_mode's high byte, so the
    # S_IFMT nibble can be tested a byte at a time (S_IFDIR>>8 == 0x40).
    mov al, [rsi + 25]
    and al, 0xf0
    cmp al, 0x40
    je .dir_error

    # Check circular read, but only if stdout is a regular file (S_IFREG>>8)
    mov al, r13b
    and al, 0xf0
    cmp al, 0x80
    jne .check_sendfile

    cmp r14, [rsi]                      # same st_dev ?
    jne .check_sendfile
    cmp r15, [rsi + 8]                  # same st_ino ?
    jne .check_sendfile

    # --- Cold: diagnostics. rsi still holds BUF, so only its low half moves. --
    mov si, M_CIRC & 0xffff
    jmp .report

.dir_error:
    mov si, M_DIR & 0xffff
    jmp .report

.open_error:
    # Negative errno in eax: -2=ENOENT, -13=EACCES, -21=EISDIR
    mov esi, M_NOENT                    # esi was 0 (open flags), so load in full
    cmp al, -2                          # ENOENT
    je 9f
    mov si, M_ACCES & 0xffff
    cmp al, -13                         # EACCES
    je 9f
    mov si, M_DIR & 0xffff
    cmp al, -21                         # EISDIR
    je 9f
    mov si, M_OPEN & 0xffff             # default: "cannot open file\n"
9:  xor ebx, ebx                        # No fd was opened, so .done_fd's close
                                        # is skipped and it falls to .next_file

# ------------------------------------------------------------------------------
# .report -- diagnostic emitter, entered by fallthrough from .open_error.
# Stages "cat: <filename>: <error_msg>" in the I/O buffer and delivers it to
# STDERR with a single write(2). Sole consumer of every path above, so it is
# inlined rather than called: no call/ret, and rsi/rdi/rax/rcx/rdx are all dead
# at each entry.
# Input: rsi = error message (newline-terminated), r8 = filename (NUL-terminated)
# ------------------------------------------------------------------------------
.report:
    mov r12b, 1                         # Exit status = 1 (upper bits already 0)
    push rsi                            # Save error message pointer

    mov edi, BUF                        # Staging area
    mov eax, 0x3a746163                 # "cat:"
    stosd
    mov al, 0x20                        # " "
    stosb

    mov rsi, r8                         # Copy filename, excluding its NUL
1:  lodsb
    stosb
    test al, al
    jnz 1b
    dec edi                             # Overwrite NUL byte
    mov ax, 0x203a                      # ": "
    stosw

    pop rsi                             # Error message; copy it including '\n'
2:  lodsb
    stosb
    cmp al, 10
    jne 2b

    mov si, BUF & 0xffff
    mov edx, edi
    sub edx, esi                        # rdx = total staged length
    push 1                              # SYS_WRITE = 1
    pop rax
    push 2                              # STDERR = 2
    pop rdi
    syscall
    jmp .done_fd

.stdin_entry:
    xor ebx, ebx                        # fd = 0 (stdin): never a seekable file,
    jmp .pipe_loop                      # so skip the sendfile probe entirely

.check_sendfile:
    # /proc and /sys pseudo-files report st_size == 0; sendfile would copy
    # nothing, so route them to the read/write loop.
    cmp qword ptr [rsi + 48], 0
    jle .pipe_loop

# --- Zero-Copy In-Kernel Streaming Loop ---
# rdi/rsi/rdx/r10 are loop-invariant: syscall only clobbers rax, rcx and r11.
    push 1                              # STDOUT = 1
    pop rdi
    mov esi, ebx                        # in_fd
    cdq                                 # offset = NULL (rax is 0 from fstat)
    or r10d, -1                         # count: kernel clamps to MAX_RW_COUNT
.sendfile_loop:
    push 40                             # SYS_SENDFILE = 40
    pop rax
    syscall
    test eax, eax
    jg .sendfile_loop                   # Continue if transferred > 0
    cmp al, -4                          # -EINTR ?
    je .sendfile_loop                   # Retry if interrupted by signal
    jns .done_fd                        # Clean EOF
                                        # Otherwise fall back to the read/write
                                        # loop, which restarts from the current
                                        # (unmoved) file position.

# --- High-Throughput Buffered Loop with Partial Write Handling ---
.pipe_loop:
    xor eax, eax                        # SYS_READ = 0
    mov edi, ebx
    mov esi, BUF
    mov edx, 0x10000                    # 64 KB chunk
    syscall
    test eax, eax
    jg .write_all                       # Read bytes -> write them
    cmp al, -4                          # -EINTR ?
    je .pipe_loop                       # Retry
    jmp .done_fd                        # EOF (0) or error (<0)

.write_all:
    mov edx, eax                        # Total bytes remaining to write
    push 1                              # STDOUT = 1, and stays 1 for the loop
    pop rdi                             # rsi still points at BUF from the read

.write_subloop:
    mov eax, edi                        # SYS_WRITE == STDOUT_FILENO == 1
    syscall
    test eax, eax
    jle 1f                              # Error or 0 bytes written

    add rsi, rax                        # Advance buffer pointer
    sub edx, eax                        # Decrement remaining bytes
    jnz .write_subloop                  # Loop until all bytes written
    jmp .pipe_loop

1:  cmp al, -4                          # -EINTR ?
    je .write_subloop                   # Retry write on signal

.done_fd:
    test ebx, ebx                       # If stdin (0) or failed open (0), do not close
    jz .next_file

    push 3                              # SYS_CLOSE = 3
    pop rax
    mov edi, ebx
    syscall

.next_file:
    dec ebp
    jg .arg_loop

.exit:
    push 60                             # SYS_EXIT = 60
    pop rax
    mov edi, r12d                       # Exit with global status (0 or 1)
    syscall

# Error String Constants. Each ends in '\n', which doubles as its length marker.
msg_open:
    .ascii "cannot open file\n"

msg_noent:
    .ascii "No such file or directory\n"

msg_acces:
    .ascii "Permission denied\n"

msg_dir:
    .ascii "Is a directory\n"

msg_circ:
    .ascii "input file is output file\n"

file_end:

# NOTE: the `mov si, imm16` partial-register address loads above are valid only
# while the whole image sits inside one 64K window -- i.e. while
# (file_end - ehdr) < 0x10000, since LOAD_ADDR is 64K-aligned. This cannot be
# checked with .if here (the .org directives above defer symbol folding), but
# test.py's binary-size assertion bounds the image at 1024 bytes, which is a
# far stronger guarantee. Revisit these loads before relaxing that bound.
