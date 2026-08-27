# Extremely small ELF64 Linux executable (<200 bytes)
# Overlaps the ELF Header and Program Header to achieve ultra-compact size.
.intel_syntax noprefix

.equ LOAD_ADDR, 0x400000

.section .text
.global _start

_start:
ehdr:
    # 0x00: e_ident[0..15]
    .byte 0x7f, 'E', 'L', 'F', 2, 1, 1, 0
    .quad 0

    # 0x10:
    .word 2                         # e_type = ET_EXEC (2)
    .word 62                        # e_machine = EM_X86_64 (62)
    .long 1                         # e_version = 1

    # 0x18: e_entry (8 bytes)
    .quad LOAD_ADDR + (code_entry - ehdr)

    # 0x20: e_phoff (8 bytes) -> Point phdr to offset 0x38 (overlapping ehdr)
    .quad 0x38

    # 0x28: e_shoff (8 bytes)
    .quad 0

    # 0x30: e_flags (4 bytes), e_ehsize (2 bytes), e_phentsize (2 bytes)
    .long 0
    .word 64                        # e_ehsize
    .word 56                        # e_phentsize

    # 0x38: START OF PHDR (56 bytes) overlaps end of EHDR:
    #   p_type (4 bytes) = 1 (PT_LOAD)  -> also matches e_phnum=1, e_shentsize=0 in EHDR
    .word 1                         # e_phnum / p_type low 16-bit
    .word 0                         # e_shentsize / p_type high 16-bit
    #   p_flags (4 bytes) = 7 (PF_R | PF_W | PF_X) -> matches e_shnum=7, e_shstrndx=0
    .word 7                         # e_shnum / p_flags low 16-bit
    .word 0                         # e_shstrndx / p_flags high 16-bit
    #   (End of 64-byte EHDR)

    # Remaining PHDR fields:
    .quad 0                         # 0x40: p_offset
    .quad LOAD_ADDR                 # 0x48: p_vaddr
    .quad LOAD_ADDR                 # 0x50: p_paddr
    .quad file_end - ehdr           # 0x58: p_filesz
    .quad file_end - ehdr + 4096    # 0x60: p_memsz (allocates 4096 bytes buffer in BSS space!)
    .quad 0x1000                    # 0x68: p_align
    # End of PHDR at offset 0x70 (112 bytes total header size)

# --- Code Entry (at offset 0x70) ---
code_entry:
    pop rbp                         # rbp = argc
    pop rax                         # argv[0]
    dec ebp                         # argc - 1
    jz .read_loop                   # If no args, ebx=0 (stdin)

.arg_loop:
    pop rdi                         # rdi = argv[i]

    xor ebx, ebx                    # Default ebx = 0 (stdin)
    cmp word ptr [rdi], 0x002d      # "-" ?
    je .read_loop

    # sys_open(rdi, 0, 0)
    push 2
    pop rax
    xor esi, esi
    xor edx, edx
    syscall
    test eax, eax
    js .next_file
    xchg ebx, eax                   # ebx = fd

.read_loop:
    # sys_read(fd=ebx, buf=file_end, count=512)
    xor eax, eax
    mov edi, ebx
    lea rsi, [rip + file_end]
    push 127
    pop rdx
    syscall
    test eax, eax
    jle .done_fd

    # sys_write(STDOUT=1, buf=file_end, count=eax)
    xchg edx, eax
    push 1
    pop rax
    mov edi, eax
    syscall
    jmp .read_loop

.done_fd:
    test ebp, ebp                   # If stdin_only mode (argc=0), exit
    jz .exit

    test ebx, ebx                   # If stdin, don't close
    jz .next_file

    push 3                          # sys_close(ebx)
    pop rax
    mov edi, ebx
    syscall

.next_file:
    dec ebp
    jnz .arg_loop

.exit:
    push 60                         # sys_exit(0)
    pop rax
    xor edi, edi
    syscall

file_end:
