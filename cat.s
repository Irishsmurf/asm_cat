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

.org 0x08
entry:
    push 5
    pop rax
    inc edi
    jmp hole2

.org 0x10
    .word 2
    .word 62
    .long 1
    .quad LOAD_ADDR + (entry - ehdr)
    .quad 0x38

.org 0x28
hole2:
    mov esi, BUF
    syscall
    mov r13b, [rsi + 25]
    jmp hole4

.org 0x36
    .word 56
    .word 1
    .word 0
    .word 7
    .word 0
    .quad 0
    .quad LOAD_ADDR

.org 0x50
exit_routine:
    push 60
    pop rax
    mov edi, r12d
    syscall

.org 0x58
    .quad file_end - ehdr
    .quad file_end - ehdr + 0x30000

.org 0x68
hole4:
    mov r14, [rsi]
    pop rbp
    pop rax
    sub ebp, 1

.org 0x70
code_entry:
    mov r15, [rsi + 8]
    jz .stdin_entry

.arg_loop:
    pop rdi
    test r9d, r9d
    jnz .process_as_file
    cmp word ptr [rdi], 0x2d2d
    jne .check_stdin_dash
    cmp byte ptr [rdi + 2], 0
    jne .check_stdin_dash
    inc r9d
    jmp .next_file
.check_stdin_dash:
    cmp word ptr [rdi], 0x002d
    jne .process_as_file
.stdin_entry:
    xor ebx, ebx
    jmp .pipe_loop
.next_file:
    dec ebp
    jg .arg_loop
    jmp exit_routine

.process_as_file:
    mov r8, rdi
    push 2
    pop rax
    xor esi, esi
    cdq
    syscall
    test eax, eax
    js .open_error
    
    xchg edi, eax
    push 5
    pop rax
    mov esi, BUF
    syscall
    mov ebx, edi

    mov al, [rsi + 25]
    and al, 0xf0
    cmp al, 0x40
    je .dir_error

    mov al, r13b
    and al, 0xf0
    cmp al, 0x80
    jne .check_sendfile

    cmp r14, [rsi]
    jne .check_sendfile
    cmp r15, [rsi + 8]
    jne .check_sendfile

.circular_error:
    mov si, M_CIRC & 0xffff
    jmp .report
.dir_error:
    mov si, M_DIR & 0xffff
    jmp .report
.open_error:
    mov esi, M_NOENT
    cmp al, -2
    je 9f
    mov si, M_ACCES & 0xffff
    cmp al, -13
    je 9f
    mov si, M_DIR & 0xffff
    cmp al, -21
    je 9f
    mov si, M_OPEN & 0xffff
9:  xor ebx, ebx
    jmp .report

.check_sendfile:
    cmp dword ptr [rsi + 48], 0
    jle .pipe_loop
    push 1
    pop rdi
    mov esi, ebx
    cdq
    or r10d, -1
.sendfile_loop:
    push 40
    pop rax
    syscall
    test eax, eax
    jg .sendfile_loop
    cmp al, -4
    je .sendfile_loop
    jns .done_fd

.pipe_loop:
    xor eax, eax
    mov edi, ebx
    mov esi, BUF
    mov edx, 0x10000
    syscall
    test eax, eax
    jg .write_all
    cmp al, -4
    je .pipe_loop
    jmp .done_fd
.write_all:
    mov edx, eax
    push 1
    pop rdi
.write_subloop:
    mov eax, edi
    syscall
    test eax, eax
    jle 1f
    add rsi, rax
    sub edx, eax
    jnz .write_subloop
    jmp .pipe_loop
1:  cmp al, -4
    je .write_subloop

.done_fd:
    test ebx, ebx
    jz .next_file
    push 3
    pop rax
    mov edi, ebx
    syscall
    jmp .next_file

.report:
    inc r12d
    push rsi
    mov edi, BUF
    mov eax, 0x3a746163
    stosd
    mov al, 0x20
    stosb
    mov rsi, r8
1:  lodsb
    stosb
    test al, al
    jnz 1b
    dec edi
    mov ax, 0x203a
    stosw
    pop rsi
3:  lodsb
    stosb
    cmp al, 10
    jne 3b
    mov si, BUF & 0xffff
    mov edx, edi
    sub edx, esi
    push 1
    pop rax
    push 2
    pop rdi
    syscall
    jmp .done_fd

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
