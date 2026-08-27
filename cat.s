# Simple naive 'cat' implementation for Linux x86_64 using GNU Assembler (GAS)
# Supports:
#   1) Reading from stdin when no arguments are provided or '-' is passed
#   2) Reading from multiple files passed as command-line arguments

.intel_syntax noprefix

.equ SYS_READ, 0
.equ SYS_WRITE, 1
.equ SYS_OPEN, 2
.equ SYS_CLOSE, 3
.equ SYS_EXIT, 60

.equ STDIN_FD, 0
.equ STDOUT_FD, 1
.equ STDERR_FD, 2

.equ O_RDONLY, 0
.equ BUF_SIZE, 4096

.section .bss
    .lcomm buffer, BUF_SIZE

.section .rodata
    err_msg:
        .ascii "cat: cannot open file\n"
    .equ ERR_MSG_LEN, . - err_msg

.section .text
.global _start

_start:
    # Stack layout on x86_64 entry:
    # [rsp]       = argc
    # [rsp + 8]   = argv[0] (program name)
    # [rsp + 16]  = argv[1] ...
    mov r12, [rsp]         # r12 = argc
    lea r13, [rsp + 16]    # r13 = &argv[1]

    # If argc <= 1 (no file arguments), read from stdin
    cmp r12, 1
    jle .read_stdin_only

    # Loop through arguments
.arg_loop:
    cmp r12, 1
    jle .exit_success

    mov rdi, [r13]         # rdi = current argv[i] pointer
    
    # Check if argument is "-" (stdin alias)
    cmp byte ptr [rdi], '-'
    jne .open_regular_file
    cmp byte ptr [rdi + 1], 0
    jne .open_regular_file

    # Read from STDIN
    mov rdi, STDIN_FD
    call cat_fd
    jmp .next_arg

.open_regular_file:
    # sys_open(filename=rdi, flags=O_RDONLY, mode=0)
    mov rax, SYS_OPEN
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall

    test rax, rax
    js .open_error         # If negative, open failed

    mov r14, rax           # Save file descriptor
    mov rdi, r14
    call cat_fd

    # sys_close(fd=r14)
    mov rax, SYS_CLOSE
    mov rdi, r14
    syscall

.next_arg:
    add r13, 8             # Move to next argv element
    dec r12                # Decrement remaining arg count
    jmp .arg_loop

.read_stdin_only:
    mov rdi, STDIN_FD
    call cat_fd
    jmp .exit_success

.open_error:
    # Print error message to stderr
    mov rax, SYS_WRITE
    mov rdi, STDERR_FD
    lea rsi, [rip + err_msg]
    mov rdx, ERR_MSG_LEN
    syscall
    jmp .next_arg

.exit_success:
    mov rax, SYS_EXIT
    xor rdi, rdi           # exit code 0
    syscall

# -------------------------------------------------------------
# cat_fd: Reads from file descriptor in RDI and writes to STDOUT
# -------------------------------------------------------------
cat_fd:
    push rbx
    mov rbx, rdi           # rbx = fd to read from

.read_loop:
    # sys_read(fd=rbx, buf=buffer, count=BUF_SIZE)
    mov rax, SYS_READ
    mov rdi, rbx
    lea rsi, [rip + buffer]
    mov rdx, BUF_SIZE
    syscall

    test rax, rax
    jle .cat_fd_done       # If <= 0 (EOF or error), finish

    # sys_write(fd=STDOUT_FD, buf=buffer, count=bytes_read)
    mov rdx, rax           # rdx = number of bytes read
    mov rax, SYS_WRITE
    mov rdi, STDOUT_FD
    lea rsi, [rip + buffer]
    syscall

    jmp .read_loop

.cat_fd_done:
    pop rbx
    ret
