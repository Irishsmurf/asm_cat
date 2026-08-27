.intel_syntax noprefix
.equ LOAD_ADDR, 0x400000
.equ BUF,      LOAD_ADDR + (file_end   - ehdr)
.equ M_OPEN,   LOAD_ADDR + (msg_open   - ehdr)
.equ M_NOENT,  LOAD_ADDR + (msg_noent  - ehdr)
.equ M_ACCES,  LOAD_ADDR + (msg_acces  - ehdr)
.equ M_DIR,    LOAD_ADDR + (msg_dir    - ehdr)
.equ M_CIRC,   LOAD_ADDR + (msg_circ   - ehdr)

.section .text
.global _start

_start:
ehdr:
    .byte 0x7f, 'E', 'L', 'F', 2, 1, 1, 0

# --- Code Hole 1: e_ident padding (8 bytes, 100% packed!) ---
.org 0x08
entry:
    mov r13d, BUF                       # r13 = BUF, kept live for the whole run
    jmp hole2                           # Hop to hole 2 (exactly 8 bytes)

.org 0x10
    .word 2                             # e_type = ET_EXEC
    .word 62                            # e_machine = EM_X86_64
    .long 1                             # e_version = 1
    .quad LOAD_ADDR + (entry - ehdr)    # e_entry
    .quad 0x38                          # e_phoff: Points to offset 0x38

# --- Code Hole 2: e_shoff, e_flags, e_ehsize (14 bytes) ---
.org 0x28
hole2:
    push 5                              # SYS_FSTAT = 5
    pop rax
    inc edi                             # fd = 1 (stdout)
    mov esi, r13d                       # BUF is used as statbuf
    syscall                             # sys_fstat(1, BUF)
    jmp hole4

.org 0x36
    .word 56                            # e_phentsize
    .word 1                             # e_phnum / p_type low
    .word 0                             # e_shentsize / p_type high
    .word 7                             # e_shnum / p_flags low
    .word 0                             # e_shstrndx / p_flags high
    .quad 0                             # p_offset
    .quad LOAD_ADDR                     # p_vaddr

# --- Code Hole 3: p_paddr (8 bytes, ignored by Linux) ---
.org 0x50
exit_routine:
    push 60                             # SYS_EXIT = 60
    pop rax
    mov edi, r12d                       # Exit with global status (0 or 1)
    syscall

.org 0x58
    .quad file_end - ehdr               # p_filesz
    .quad file_end - ehdr + 0x30000     # p_memsz (192 KB mapped BSS for free!)

# --- Code Hole 4: p_align (8 bytes, ignored by Linux) ---
.org 0x68
hole4:
    mov r14, [rsi]                      # Load stdout st_dev
    pop rbp                             # rbp = argc
    pop rax                             # Discard argv[0]
    sub ebp, 1                          # EXACTLY 3 bytes to perfectly fill hole

# --- Clean Fallthrough to Code Entry ---
.org 0x70
code_entry:
    mov r15, [rsi + 8]                  # Load stdout st_ino
    jz .stdin_entry                     # If argc == 1 (sub ebp, 1 set ZF), read stdin

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
    jne .process_as_file

.stdin_entry:
    xor ebx, ebx                        # fd = 0 (stdin): never a seekable file,
    jmp .pipe_loop                      # so skip the sendfile probe entirely

.next_file:
    dec ebp
    jg .arg_loop
    jmp exit_routine                    # Jump back into ELF hole 3!

.process_as_file:
    mov r8, rdi                         # Preserve filename in r8

    # sys_open(filename=rdi, flags=O_RDONLY (0), mode=0)
    push 2                              # SYS_OPEN = 2
    pop rax
    xor esi, esi                        # flags = O_RDONLY (0).
    syscall
    test eax, eax
    js .open_error                      # Negative errno returned
    
    xchg edi, eax                       # edi = fd (xchg is only 1 byte!)
    
    # sys_fstat(fd=edi, statbuf=&file_end)
    push 5                              # SYS_FSTAT = 5
    pop rax
    mov esi, r13d                       # statbuf = BUF
    syscall
    mov ebx, edi                        # Save fd in ebx

    # Check if directory. Byte 25 of struct stat is st_mode's high byte, so the
    # S_IFMT nibble can be tested a byte at a time (S_IFDIR>>8 == 0x40).
    mov al, [rsi + 25]
    and al, 0xf0
    cmp al, 0x40
    je .dir_error

    # Circular read check: compare the input file's st_dev/st_ino against
    # stdout's (captured at startup in r14/r15).
    cmp r14, [rsi]                      # same st_dev ?
    jne .check_sendfile
    cmp r15, [rsi + 8]                  # same st_ino ?
    jne .check_sendfile

    # --- Cold: diagnostics. rsi still holds BUF, so only its low half moves. --
.circular_error:
    mov si, M_CIRC & 0xffff
    jmp .report

.dir_error:
    mov si, M_DIR & 0xffff
    jmp .report

.open_error:
    # open(2) failed; al holds negative errno: -2=ENOENT, -13=EACCES.
    # Load 32-bit address since LOAD_ADDR is 0x400000.
    mov esi, M_NOENT                    # ENOENT
    cmp al, -2
    je 9f
    mov si, M_ACCES & 0xffff            # EACCES
    cmp al, -13
    je 9f
    mov si, M_OPEN & 0xffff             # default: "cannot open file\n"
9:  xor ebx, ebx                        # No fd was opened -> close skipped
    jmp .report

.check_sendfile:
    # /proc and /sys pseudo-files report st_size == 0; sendfile would copy
    # nothing, so route them to the read/write loop.
    cmp dword ptr [rsi + 48], 0         # 4-byte cmp is safe: exact 4GB files
    jle .pipe_loop                      # just fall back to slower pipe_loop

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
    mov esi, r13d                       # buffer = BUF
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

    add esi, eax                        # Advance buffer pointer
    sub edx, eax                        # Decrement remaining bytes
    jnz .write_subloop                  # Loop until all bytes written
    jmp .pipe_loop

1:  cmp al, -4                          # -EINTR ?
    je .write_subloop                   # Retry write on signal

.done_fd:
    test ebx, ebx                       # If stdin (0) or failed open (0), do not close
    jz 1f                               # skip the close, but still advance args
    push 3                              # SYS_CLOSE = 3
    pop rax
    mov edi, ebx
    syscall
1:  jmp .next_file                      # single back-edge shared by both paths

# ------------------------------------------------------------------------------
# .report -- diagnostic emitter, entered by jump from error paths.
# Stages "cat: <filename>: <error_msg>" in the I/O buffer and delivers it to
# STDERR with a single write(2). 
# Input: rsi = error message (newline-terminated), r8 = filename (NUL-terminated)
# ------------------------------------------------------------------------------
.report:
    inc r12d                            # Exit status = 1 (upper bits already 0)
    push rsi                            # Save error message pointer

    mov edi, r13d                       # Staging area = BUF
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
3:  lodsb
    stosb
    cmp al, 10
    jne 3b

    mov esi, r13d                       # rsi = BUF (write buffer + length base)
    mov edx, edi
    sub edx, esi                        # rdx = total staged length
    push 1                              # SYS_WRITE = 1
    pop rax
    push 2                              # STDERR = 2
    pop rdi
    syscall
    jmp .done_fd

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
