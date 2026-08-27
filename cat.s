# ==============================================================================
# asm_cat: Ultra-compact, Safe & High-Performance UNIX 'cat' in x86_64 Assembly
#
# Features:
# 1. Zero-Copy In-Kernel sys_sendfile (syscall 40) for regular non-empty files.
# 2. 64 KB dynamically mapped fallback buffer for pipes/stdin/proc/sys files.
# 3. Directory Detection: "cat: Is a directory"
# 4. Special /proc & /sys Pseudo-File Support
# 5. Circular Read / Self-Append Prevention: "cat: input file is output file"
# 6. Overlapped ELF64 Headers: 112 header bytes.
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
    push 5
    pop rax
    push 1
    pop rdi
    lea rsi, [rip + file_end]
    syscall

    mov r14, [rsi]                  # stdout st_dev
    mov r15, [rsi + 8]              # stdout st_ino
    mov r13w, [rsi + 24]            # stdout st_mode

    xor r12d, r12d                  # global exit status (0 = success)

    pop rbp                         # argc
    pop rax                         # argv[0]
    dec ebp                         # argc - 1
    jz .pipe_loop                   # If no args, stream stdin (ebx=0)

.arg_loop:
    pop rdi                         # rdi = argv[i]

    xor ebx, ebx                    # Default ebx = 0 (stdin)
    cmp word ptr [rdi], 0x002d      # Is "-" ?
    je .pipe_loop

    # sys_open(rdi, 0, 0)
    push 2
    pop rax
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .open_error
    xchg ebx, eax                   # ebx = fd

    # sys_fstat(ebx, &file_end)
    push 5
    pop rax
    mov edi, ebx
    lea rsi, [rip + file_end]
    syscall

    # Check directory: (st_mode & 0xf000) == 0x4000
    mov ax, [rsi + 24]
    and ah, 0xf0
    cmp ah, 0x40
    je .dir_error

    # Check circular read if stdout is regular file (st_mode & 0xf000 == 0x8000)
    and r13b, 0xf0
    cmp r13b, 0x80
    jne .check_sendfile

    cmp r14, [rsi]
    jne .check_sendfile
    cmp r15, [rsi + 8]
    jne .check_sendfile

.circular_error:
    lea rsi, [rip + msg_circ]
    push 26
    pop rdx
    call print_error
    jmp .done_fd

.dir_error:
    lea rsi, [rip + msg_dir]
    push 17
    pop rdx
    call print_error
    jmp .done_fd

.open_error:
    lea rsi, [rip + msg_open]
    push 17
    pop rdx
    call print_error
    jmp .next_file

.check_sendfile:
    # If st_size == 0 (/proc, /sys), route to pipe loop
    cmp qword ptr [rsi + 48], 0
    jle .pipe_loop

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
    jg .sendfile_loop
    jns .done_fd

.pipe_loop:
    xor eax, eax                    # SYS_READ
    mov edi, ebx
    lea rsi, [rip + file_end]
    mov edx, 0x10000
    syscall
    test eax, eax
    jle .done_fd

    xchg edx, eax                   # bytes read
    push 1                          # SYS_WRITE
    pop rax
    mov edi, eax
    syscall
    jmp .pipe_loop

.done_fd:
    test ebp, ebp
    jz .exit

    test ebx, ebx
    jz .next_file

    push 3                          # SYS_CLOSE
    pop rax
    mov edi, ebx
    syscall

.next_file:
    dec ebp
    jnz .arg_loop

.exit:
    push 60                         # SYS_EXIT
    pop rax
    mov edi, r12d
    syscall

print_error:
    mov r12d, 1                     # error exit code = 1
    # write(2, "cat: <msg>", rdx + 5)
    # The messages are laid out so "cat: " prefixes them or we write both in one sequence
    push rdx
    push rsi
    push 1
    pop rax
    push 2
    pop rdi
    lea rsi, [rip + msg_prefix]
    push 5
    pop rdx
    syscall

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
