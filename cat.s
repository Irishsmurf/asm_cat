# ==============================================================================
# asm_cat: Ultra-compact UNIX 'cat' utility in x86_64 Linux Assembly
#
# Binary size: Exactly 197 bytes
#
# Key Architectural Highlights:
# 1. Overlapping Headers: The ELF64 Header (Elf64_Ehdr, 64 bytes) and the
#    Program Header (Elf64_Phdr, 56 bytes) are overlapped at offset 0x38.
#    This reduces the combined header size from 120 bytes down to 112 bytes.
# 2. In-Memory BSS Expansion: `p_memsz` in PT_LOAD is set to `filesz + 4096`,
#    instructing the Linux ELF loader to map a zero-initialized 4 KB buffer
#    immediately past the end of the file image without storing it on disk.
# 3. Stack Argument Traversal: Leverages the initial stack state set up by the
#    kernel (argc, argv pointers) to pop command-line arguments directly.
# 4. Dense Machine Code: Uses short immediate encodings, register exchanges,
#    and a shared I/O loop to minimize byte footprint.
# ==============================================================================

.intel_syntax noprefix

# Base virtual address where this executable image is loaded into memory
.equ LOAD_ADDR, 0x400000

.section .text
.global _start

_start:

# ==============================================================================
# 1. ELF HEADER (Elf64_Ehdr) & OVERLAPPED PROGRAM HEADER (Elf64_Phdr)
# ==============================================================================
ehdr:
    # --- 0x00: e_ident[16] (ELF Identification) ---
    .byte 0x7f, 'E', 'L', 'F'       # Magic number: 0x7f, 'E', 'L', 'F'
    .byte 2                         # EI_CLASS: 2 = ELFCLASS64 (64-bit architecture)
    .byte 1                         # EI_DATA: 1 = ELFDATA2LSB (Little Endian)
    .byte 1                         # EI_VERSION: 1 = EV_CURRENT
    .byte 0                         # EI_OSABI: 0 = ELFOSABI_NONE / System V
    .quad 0                         # EI_PAD: 8 bytes of padding (0x08 - 0x0F)

    # --- 0x10: ELF File Type, Target Architecture & Version ---
    .word 2                         # e_type: 2 = ET_EXEC (Executable file)
    .word 62                        # e_machine: 62 (0x3E) = EM_X86_64
    .long 1                         # e_version: 1 = Current version

    # --- 0x18: Virtual Memory Entry Point Address ---
    # Points directly to our code_entry label in memory
    .quad LOAD_ADDR + (code_entry - ehdr)

    # --- 0x20: Program Header Table File Offset (e_phoff) ---
    # Points to 0x38, overlapping the program header with the end of the ELF header
    .quad 0x38

    # --- 0x28: Section Header Table File Offset (e_shoff) ---
    # 0 = No section header table included in the final binary
    .quad 0

    # --- 0x30: ELF Flags & Header Sizes ---
    .long 0                         # e_flags: 0 (unused on x86_64)
    .word 64                        # e_ehsize: Size of Elf64_Ehdr (64 bytes)
    .word 56                        # e_phentsize: Size of Elf64_Phdr (56 bytes)

    # --- 0x38: OVERLAP REGION (Offset 0x38 - 0x3F) ---
    # These 8 bytes serve dual roles:
    # As Elf64_Ehdr fields (offsets 0x38 - 0x3F):
    #   - e_phnum     = 1 (1 Program Header)
    #   - e_shentsize = 0 (no section headers)
    #   - e_shnum     = 7 (dummy value, ignored since e_shoff=0)
    #   - e_shstrndx  = 0
    # As Elf64_Phdr fields (offsets 0x00 - 0x07 of PT_LOAD header):
    #   - p_type  = 1 (0x00000001 = PT_LOAD, loadable segment)
    #   - p_flags = 7 (0x00000007 = PF_R | PF_W | PF_X: Read/Write/Execute)
    .word 1                         # e_phnum (16-bit)     | p_type (low 16-bit)
    .word 0                         # e_shentsize (16-bit) | p_type (high 16-bit)
    .word 7                         # e_shnum (16-bit)     | p_flags (low 16-bit)
    .word 0                         # e_shstrndx (16-bit)  | p_flags (high 16-bit)
    # [End of 64-byte Elf64_Ehdr at offset 0x40]

    # --- 0x40: Remaining Program Header Fields (Elf64_Phdr continuation) ---
    .quad 0                         # p_offset: File offset of segment (0 = whole file)
    .quad LOAD_ADDR                 # p_vaddr: Virtual address in process memory
    .quad LOAD_ADDR                 # p_paddr: Physical address (ignored by Linux)
    .quad file_end - ehdr           # p_filesz: Exact on-disk file size (197 bytes)
    .quad file_end - ehdr + 4096    # p_memsz: Memory size with extra 4 KB BSS buffer
    .quad 0x1000                    # p_align: 4 KB page alignment
    # [End of Elf64_Phdr at offset 0x70; Total header size = 112 bytes]


# ==============================================================================
# 2. CODE ENTRY POINT & EXECUTION LOGIC (Offset 0x70)
# ==============================================================================
code_entry:
    # Linux initial stack layout on process entry:
    #   [rsp]     = argc (argument count)
    #   [rsp+8]   = argv[0] (pointer to program name string)
    #   [rsp+16]  = argv[1] (pointer to 1st argument string) ...
    pop rbp                         # rbp = argc
    pop rax                         # rax = argv[0] (discard program name)

    # Check if any file arguments were provided
    dec ebp                         # ebp = argc - 1 (number of arguments)
    jz .read_loop                   # If ebp == 0, no args: read from stdin (ebx is 0)

.arg_loop:
    pop rdi                         # rdi = current argv[i] pointer

    # Check if the argument is "-" (alias for standard input)
    # We compare 2 bytes: '-' (0x2d) followed by the null terminator '\0' (0x00)
    xor ebx, ebx                    # Default file descriptor = 0 (STDIN_FILENO)
    cmp word ptr [rdi], 0x002d      # Is argv[i] == "-"?
    je .read_loop                   # If yes, process stdin directly

    # Open the file: sys_open(filename=rdi, flags=O_RDONLY (0), mode=0)
    push 2                          # SYS_OPEN syscall number = 2
    pop rax                         # rax = 2
    xor esi, esi                    # rsi = O_RDONLY (0)
    xor edx, edx                    # rdx = mode (0)
    syscall

    # Check if open failed (returned negative error code in eax)
    test eax, eax
    js .next_file                   # If negative, skip unreadable file

    xchg ebx, eax                   # ebx = opened file descriptor

# ------------------------------------------------------------------------------
# Core I/O Loop: Read from FD (in ebx) and write to STDOUT (FD 1)
# ------------------------------------------------------------------------------
.read_loop:
    # sys_read(fd=ebx, buf=&file_end, count=127)
    # The buffer resides at file_end in the zero-initialized BSS memory segment
    xor eax, eax                    # SYS_READ syscall number = 0
    mov edi, ebx                    # edi = file descriptor to read
    lea rsi, [rip + file_end]       # rsi = pointer to BSS I/O buffer
    push 127                        # 1-byte immediate push for chunk size
    pop rdx                         # rdx = 127 bytes
    syscall

    # Check read return value
    test eax, eax
    jle .done_fd                    # If <= 0 (EOF or error), finished with this FD

    # sys_write(fd=STDOUT (1), buf=&file_end, count=bytes_read)
    xchg edx, eax                   # edx = number of bytes read
    push 1                          # SYS_WRITE syscall number = 1
    pop rax                         # rax = 1
    mov edi, eax                    # edi = STDOUT_FILENO (1)
    # (rsi still points to the buffer from sys_read)
    syscall
    jmp .read_loop                  # Continue reading until EOF

.done_fd:
    # Check if we were reading in stdin-only mode (ebp was 0 initially)
    test ebp, ebp
    jz .exit                        # If no file arguments, exit immediately

    # If the file descriptor was stdin (ebx == 0), do not close it
    test ebx, ebx
    jz .next_file

    # sys_close(fd=ebx)
    push 3                          # SYS_CLOSE syscall number = 3
    pop rax                         # rax = 3
    mov edi, ebx                    # edi = fd to close
    syscall

.next_file:
    # Advance to next command-line argument
    dec ebp
    jnz .arg_loop

# ------------------------------------------------------------------------------
# Process Exit
# ------------------------------------------------------------------------------
.exit:
    # sys_exit(status=0)
    push 60                         # SYS_EXIT syscall number = 60
    pop rax                         # rax = 60
    xor edi, edi                    # edi = 0 (exit status SUCCESS)
    syscall

# End of on-disk binary image.
# The area immediately following this label in memory acts as our 4 KB BSS buffer.
file_end:
