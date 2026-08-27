# ==============================================================================
# asm_cat: Ultra-compact, Enterprise-Grade, High-Performance UNIX 'cat' in x86_64 ASM
# Size-optimized with deduplicated strings, shared syscall helpers, and dense encodings.
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
    # Record stdout's (st_dev, st_ino, st_mode)
    # sys_fstat(fd=1, statbuf=&file_end)
    push 5                          # SYS_FSTAT = 5
    pop rax
    push 1                          # STDOUT_FILENO = 1
    pop rdi
    lea rsi, [rip + file_end]
    syscall

    mov r14, [rsi]                  # r14 = stdout st_dev
    mov r15, [rsi + 8]              # r15 = stdout st_ino
    mov r13w, [rsi + 24]            # r13w = stdout st_mode

    xor r12d, r12d                  # r12d = global exit status (0 = success)
    xor r9d, r9d                    # r9d = raw args flag (1 if '--' encountered)

    pop rbp                         # rbp = argc
    pop rax                         # argv[0]
    dec ebp                         # argc - 1
    jz .stdin_entry                 # If no args, stream stdin (ebx=0)

.arg_loop:
    pop rdi                         # rdi = argv[i]

    # If raw mode is off, check for options
    test r9d, r9d
    jnz .process_as_file

    # Check for '--' (End of options)
    cmp word ptr [rdi], 0x2d2d      # '--' ?
    jne .check_stdin_dash
    cmp byte ptr [rdi + 2], 0       # '--\0' ?
    jne .check_stdin_dash
    inc r9d                         # Enable raw mode (r9d = 1)
    dec ebp
    jnz .arg_loop
    jmp .exit

.check_stdin_dash:
    # Check for single '-' (stdin alias)
    cmp word ptr [rdi], 0x002d      # Is '-' ?
    je .stdin_entry

.process_as_file:
    mov r8, rdi                     # Preserve filename in r8

    # sys_open(filename=rdi, flags=O_RDONLY (0), mode=0)
    push 2                          # SYS_OPEN = 2
    pop rax
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .open_error                  # Negative errno returned
    xchg ebx, eax                   # ebx = fd

    # sys_fstat(fd=ebx, statbuf=&file_end)
    push 5                          # SYS_FSTAT = 5
    pop rax
    mov edi, ebx
    lea rsi, [rip + file_end]
    syscall

    # Check if directory: (st_mode & 0xf000 == 0x4000)
    mov ax, [rsi + 24]
    and ah, 0xf0
    cmp ah, 0x40
    je .dir_error

    # Check circular read if stdout is regular file
    mov ax, r13w
    and ah, 0xf0
    cmp ah, 0x80
    jne .check_sendfile

    cmp r14, [rsi]
    jne .check_sendfile
    cmp r15, [rsi + 8]
    jne .check_sendfile

.circular_error:
    lea rsi, [rip + msg_circ]
    push 26
    pop rdx
    call report_error
    jmp .done_fd

.dir_error:
    lea rsi, [rip + msg_dir]
    push 15
    pop rdx
    call report_error
    jmp .done_fd

.open_error:
    # Negative errno in eax: -2=ENOENT, -13=EACCES, -21=EISDIR
    neg eax
    lea rsi, [rip + msg_noent]
    push 26
    pop rdx
    cmp al, 2                       # ENOENT
    je 2f
    lea rsi, [rip + msg_acces]
    push 18
    pop rdx
    cmp al, 13                      # EACCES
    je 2f
    lea rsi, [rip + msg_dir]
    push 15
    pop rdx
    cmp al, 21                      # EISDIR
    je 2f
    lea rsi, [rip + msg_open]
    push 17
    pop rdx
2:  call report_error
    jmp .next_file

.stdin_entry:
    xor ebx, ebx                    # fd = 0 (stdin)

.check_sendfile:
    # If stdin or /proc /sys pseudo-file (st_size == 0), route to pipe loop
    test ebx, ebx
    jz .pipe_loop
    cmp qword ptr [rsi + 48], 0
    jle .pipe_loop

# --- Zero-Copy In-Kernel Streaming Loop ---
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
    jg .sendfile_loop               # Continue if transferred > 0
    cmp al, -4                      # -EINTR ?
    je .sendfile_loop               # Retry if interrupted by signal
    jns .done_fd                    # Clean EOF

# --- High-Throughput Buffered Loop with Partial Write Handling ---
.pipe_loop:
    xor eax, eax                    # SYS_READ = 0
    mov edi, ebx
    lea rsi, [rip + file_end]
    mov edx, 0x10000                # 64 KB chunk
    syscall
    test eax, eax
    jg .write_all                   # Read bytes -> write them
    cmp al, -4                      # -EINTR ?
    je .pipe_loop                   # Retry
    jmp .done_fd                    # EOF (0) or error (<0)

.write_all:
    mov edx, eax                    # Total bytes remaining to write
    lea rsi, [rip + file_end]       # Pointer to current write position

.write_subloop:
    push 1                          # SYS_WRITE = 1
    pop rax
    push 1                          # STDOUT = 1
    pop rdi
    syscall
    test eax, eax
    jle 1f                          # Error or 0 bytes written

    add rsi, rax                    # Advance buffer pointer
    sub edx, eax                    # Decrement remaining bytes
    jnz .write_subloop              # Loop until all bytes written
    jmp .pipe_loop

1:  cmp al, -4                      # -EINTR ?
    je .write_subloop               # Retry write on signal
    jmp .done_fd

.done_fd:
    test ebp, ebp                   # If stdin-only mode, exit
    jz .exit

    test ebx, ebx                   # If stdin (0), do not close
    jz .next_file

    push 3                          # SYS_CLOSE = 3
    pop rax
    mov edi, ebx
    syscall

.next_file:
    dec ebp
    jnz .arg_loop

.exit:
    push 60                         # SYS_EXIT = 60
    pop rax
    mov edi, r12d                   # Exit with global status (0 or 1)
    syscall

# ------------------------------------------------------------------------------
# report_error:
# Writes "cat: <filename>: <error_msg>" to STDERR (fd 2) and sets r12d = 1
# Input: r8 = filename pointer, rsi = error message string, rdx = error msg len
# ------------------------------------------------------------------------------
report_error:
    push rdx                        # Save error msg length
    push rsi                        # Save error msg string
    push r8                         # Save filename pointer
    push rbp                        # Save ebp
    push rbx                        # Save ebx
    mov r12d, 1                     # Set error status = 1

    # 1. Write "cat: "
    lea rsi, [rip + msg_prefix]
    push 5
    pop rdx
    call write_err

    # 2. Compute filename length (r8 = filename)
    mov rdi, r8                     # rdi = filename pointer
    xor eax, eax
    or rcx, -1
    repne scasb
    not rcx
    dec rcx                         # rcx = strlen(filename)

    # Write filename
    mov rsi, r8                     # rsi = filename
    mov rdx, rcx                    # rdx = length
    call write_err

    # 3. Write ": " separator
    lea rsi, [rip + msg_colon]
    push 2
    pop rdx
    call write_err

    # 4. Write specific error message
    mov rsi, [rsp + 24]             # rsi = error msg string
    mov rdx, [rsp + 32]             # rdx = error msg length
    call write_err

    pop rbx                         # Restore ebx
    pop rbp                         # Restore ebp
    pop r8                          # Clean filename
    pop rsi                         # Clean msg string
    pop rdx                         # Clean msg length
    ret

write_err:
    push 1                          # SYS_WRITE = 1
    pop rax
    push 2                          # STDERR = 2
    pop rdi
    syscall
    ret

# Error String Constants
msg_prefix:
    .ascii "cat: "

msg_colon:
    .ascii ": "

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
