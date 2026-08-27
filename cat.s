# Size-optimized naive 'cat' implementation for Linux x86_64
.intel_syntax noprefix

.equ SYS_READ, 0
.equ SYS_WRITE, 1
.equ SYS_OPEN, 2
.equ SYS_CLOSE, 3
.equ SYS_EXIT, 60
.equ BUF_SIZE, 4096

.section .bss
    .lcomm buffer, BUF_SIZE

.section .text
.global _start

_start:
    pop rbx                # rbx = argc
    pop rax                # pop argv[0] (program name)
    dec ebx                # ebx = number of file arguments
    jnz .arg_loop

    # If no arguments, push 0 (stdin fd) and cat it
    xor edi, edi
    call cat_fd
    jmp .exit

.arg_loop:
    pop rdi                # rdi = current argv[i] string pointer

    # Check if argument is "-"
    cmp word ptr [rdi], 0x002d   # '-' followed by null terminator '\0'
    jne .open_file

    xor edi, edi           # fd = 0 (stdin)
    jmp .process_fd

.open_file:
    # sys_open(rdi, O_RDONLY=0, mode=0)
    push SYS_OPEN
    pop rax
    xor esi, esi
    xor edx, edx
    syscall

    test eax, eax
    js .next_arg           # Skip on error

    mov edi, eax           # rdi = fd

.process_fd:
    push rdi               # Save fd for closing
    call cat_fd
    pop rdi                # Restore fd

    test edi, edi          # If stdin (fd 0), do not close
    jz .next_arg

    # sys_close(fd=rdi)
    push SYS_CLOSE
    pop rax
    syscall

.next_arg:
    dec ebx
    jnz .arg_loop

.exit:
    push SYS_EXIT
    pop rax
    xor edi, edi
    syscall

# -------------------------------------------------------------
# cat_fd: Read from fd in EDI, write to STDOUT (fd 1)
# -------------------------------------------------------------
cat_fd:
    push rdi               # Save input fd
.read_loop:
    # sys_read(fd=[rsp], buf=buffer, BUF_SIZE)
    xor eax, eax           # SYS_READ = 0
    mov rdi, [rsp]
    lea rsi, [rip + buffer]
    mov edx, BUF_SIZE
    syscall

    test eax, eax
    jle .done              # EOF or error

    # sys_write(STDOUT_FD=1, buf=buffer, count=eax)
    mov edx, eax
    push SYS_WRITE
    pop rax
    mov edi, eax           # STDOUT_FD = 1
    syscall

    jmp .read_loop

.done:
    pop rdi
    ret
