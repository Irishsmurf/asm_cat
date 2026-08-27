# ==============================================================================
# asm_cat: Ultra-compact, Safe & High-Performance UNIX 'cat' in x86_64 Assembly
#
# Features:
# 1. Zero-Copy In-Kernel sys_sendfile (syscall 40) for regular non-empty files.
# 2. 64 KB dynamically mapped fallback buffer for pipes/stdin/proc/sys files.
# 3. Directory Detection:
#    Detects directory inputs (S_IFDIR) and reports "cat: Is a directory" on stderr
#    with exit status 1.
# 4. Special /proc & /sys Pseudo-File Support:
#    Properly streams dynamic pseudo-files until true EOF without early termination.
# 5. Circular Read / Self-Append Prevention:
#    Uses sys_fstat (syscall 5) to inspect (st_dev, st_ino) on stdout (fd 1) and
#    input files. If both match, aborts with "cat: input file is output file".
# 6. Diagnostics & POSIX Exit Codes:
#    Prints descriptive errors on stderr (fd 2) and exits with code 1 on failure.
# 7. Overlapped ELF64 Headers: Retains compact standalone ELF binary format.
# ==============================================================================

.intel_syntax noprefix

.equ LOAD_ADDR, 0x400000

.section .text
.global _start

_start:
# ==============================================================================
# 1. ELF HEADER (Elf64_Ehdr) & OVERLAPPED PROGRAM HEADER (Elf64_Phdr)
# ==============================================================================
ehdr:
    .byte 0x7f, 'E', 'L', 'F', 2, 1, 1, 0
    .quad 0
    .word 2                         # e_type = ET_EXEC
    .word 62                        # e_machine = EM_X86_64
    .long 1                         # e_version = 1
    .quad LOAD_ADDR + (code_entry - ehdr)
    .quad 0x38                      # e_phoff: Points to offset 0x38
    .quad 0                         # e_shoff: None
    .long 0                         # e_flags
    .word 64                        # e_ehsize
    .word 56                        # e_phentsize

    # --- Overlap Region at Offset 0x38 (8 bytes) ---
    .word 1                         # e_phnum     (1) | p_type  = PT_LOAD (1)
    .word 0                         # e_shentsize (0) | p_type  (high 16-bit)
    .word 7                         # e_shnum     (7) | p_flags = PF_R|PF_W|PF_X (7)
    .word 0                         # e_shstrndx  (0) | p_flags (high 16-bit)

    # --- Program Header Fields ---
    .quad 0                         # p_offset
    .quad LOAD_ADDR                 # p_vaddr
    .quad LOAD_ADDR                 # p_paddr
    .quad file_end - ehdr           # p_filesz
    .quad file_end - ehdr + 0x10000 # p_memsz: 64 KB dynamically mapped BSS buffer
    .quad 0x1000                    # p_align

# ==============================================================================
# 2. CODE ENTRY POINT & EXECUTION LOGIC (Offset 0x70)
# ==============================================================================
code_entry:
    # Query stdout fstat to record stdout's (st_dev, st_ino, st_mode)
    # sys_fstat(fd=1, statbuf=&file_end)
    push 5                          # SYS_FSTAT = 5
    pop rax
    push 1                          # STDOUT_FILENO = 1
    pop rdi
    lea rsi, [rip + file_end]
    syscall

    # Save stdout's st_dev in r14, st_ino in r15, and st_mode in r13
    mov r14, [rsi]                  # r14 = stdout st_dev (offset 0)
    mov r15, [rsi + 8]              # r15 = stdout st_ino (offset 8)
    mov r13, [rsi + 24]             # r13 = stdout st_mode (offset 24)
    and r13w, 0xf000                # S_IFMT mask

    xor r12d, r12d                  # r12d = global exit status (0 = success)

    pop rbp                         # rbp = argc
    pop rax                         # argv[0]
    dec ebp                         # argc - 1
    jz .pipe_loop                   # If no args, stream stdin (ebx=0)

.arg_loop:
    pop rdi                         # rdi = argv[i]

    xor ebx, ebx                    # Default ebx = 0 (stdin)
    cmp word ptr [rdi], 0x002d      # Is "-" ?
    je .pipe_loop

    # sys_open(filename=rdi, flags=O_RDONLY (0), mode=0)
    push 2                          # SYS_OPEN = 2
    pop rax
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .open_error                  # Report open error
    xchg ebx, eax                   # ebx = fd

    # sys_fstat(fd=ebx, statbuf=&file_end)
    push 5                          # SYS_FSTAT = 5
    pop rax
    mov edi, ebx
    lea rsi, [rip + file_end]
    syscall
    test eax, eax
    js .pipe_loop

    # Check if input is a directory (st_mode & 0xf000 == 0x4000)
    mov ax, [rsi + 24]
    and ax, 0xf000
    cmp ax, 0x4000                  # S_IFDIR = 0x4000
    je .dir_error

    # Check for circular read only if stdout is a regular file (S_IFREG = 0x8000)
    cmp r13w, 0x8000
    jne .check_sendfile

    # If in_file st_dev == stdout st_dev && in_file st_ino == stdout st_ino -> Circular!
    cmp r14, [rsi]
    jne .check_sendfile
    cmp r15, [rsi + 8]
    jne .check_sendfile

.circular_error:
    lea rsi, [rip + msg_circ]
    push 26                         # msg_circ_len
    pop rdx
    call print_error
    jmp .done_fd

.dir_error:
    lea rsi, [rip + msg_dir]
    push 17                         # msg_dir_len
    pop rdx
    call print_error
    jmp .done_fd

.open_error:
    lea rsi, [rip + msg_open]
    push 17                         # msg_open_len
    pop rdx
    call print_error
    jmp .next_file

.check_sendfile:
    # If file size (st_size at offset 48) == 0, it is likely a /proc or /sys pseudo-file.
    # sys_sendfile reports 0 bytes on 0-sized pseudo-files.
    # Fall back immediately to .pipe_loop for dynamic /proc and /sys streaming.
    cmp qword ptr [rsi + 48], 0
    jle .pipe_loop

    # Fast path: sys_sendfile loop for regular files (transfers until EOF)
.sendfile_loop:
    push 40                         # SYS_SENDFILE = 40
    pop rax
    push 1                          # STDOUT = 1
    pop rdi
    mov esi, ebx
    xor edx, edx
    mov r10d, 0x7ffff000
    syscall
    test eax, eax
    jg .sendfile_loop               # Continue if transferred > 0 bytes
    jns .done_fd                    # If 0 (clean EOF), done!

# ------------------------------------------------------------------------------
# High-Throughput Fallback I/O Loop (for stdin pipes, /proc, /sys, pseudo-files)
# ------------------------------------------------------------------------------
.pipe_loop:
    # sys_read(fd=ebx, buf=&file_end, count=64KB)
    xor eax, eax                    # SYS_READ = 0
    mov edi, ebx
    lea rsi, [rip + file_end]
    mov edx, 0x10000
    syscall
    test eax, eax
    jle .done_fd

    # sys_write(fd=STDOUT (1), buf=&file_end, count=bytes_read)
    xchg edx, eax
    push 1                          # SYS_WRITE = 1
    pop rax
    mov edi, eax                    # STDOUT = 1
    syscall
    jmp .pipe_loop

.done_fd:
    test ebp, ebp                   # If stdin_only mode, exit
    jz .exit

    test ebx, ebx                   # If stdin, don't close
    jz .next_file

    # sys_close(fd=ebx)
    push 3                          # SYS_CLOSE = 3
    pop rax
    mov edi, ebx
    syscall

.next_file:
    dec ebp
    jnz .arg_loop

.exit:
    # sys_exit(status=r12d)
    push 60                         # SYS_EXIT = 60
    pop rax
    mov edi, r12d                   # Exit with global error status (1 on error)
    syscall

# ------------------------------------------------------------------------------
# print_error helper:
# Writes "cat: <error message>" to STDERR (fd 2) and sets r12d = 1
# ------------------------------------------------------------------------------
print_error:
    push rdx                        # Save message length
    push rsi                        # Save message text
    mov r12d, 1                     # Set error exit status = 1

    # sys_write(STDERR_FILENO, msg_prefix, 5)
    push 1                          # SYS_WRITE = 1
    pop rax
    push 2                          # STDERR = 2
    pop rdi
    lea rsi, [rip + msg_prefix]
    push 5
    pop rdx
    syscall

    # sys_write(STDERR_FILENO, msg_text, msg_len)
    pop rsi
    pop rdx
    push 1
    pop rax
    push 2
    pop rdi
    syscall
    ret

# Error Strings
msg_prefix:
    .ascii "cat: "

msg_open:
    .ascii "cannot open file\n"

msg_circ:
    .ascii "input file is output file\n"

msg_dir:
    .ascii "Is a directory\n"

file_end:
