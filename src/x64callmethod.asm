; Win64 unwind-aware replacement for CallMethod from the Synopse mORMot
; framework 2 - (C) Arnaud Bouchez - https://synopse.info
; Original source: src/core/mormot.core.interfaces.pas at the commit pinned
; in ../mormot.lock. Original tri-license: MPL 1.1/GPL 2.0/LGPL 2.1 - see
; the mORMot 2 LICENCE.md. This replacement adds Win64 unwind metadata and
; the demonstrated FPC 3.2.2 Win64 Currency return convention.

option casemap:none

.code

PUBLIC x64callmethod

x64callmethod PROC FRAME

    push    rbp
    .pushreg rbp

    push    r12
    .pushreg r12

    mov     rbp, rsp
    .setframe rbp, 0

    .endprolog

    ; same behavior as current FPC CallMethod
    lea     rsp, [rsp-100h]
    and     rsp, -16

    ; Args = RCX
    mov     r12, rcx

    ; StackSize / StackAddr
    mov     rcx, qword ptr [r12+00h]
    mov     rdx, qword ptr [r12+08h]

    test    ecx, ecx
    jz      stack_done

stack_loop:
    push    qword ptr [rdx]
    sub     rdx, 8
    sub     ecx, 1
    jnz     stack_loop

stack_done:

    ; ParamRegs
    mov     rcx, qword ptr [r12+18h]
    mov     rdx, qword ptr [r12+20h]
    mov     r8,  qword ptr [r12+28h]
    mov     r9,  qword ptr [r12+30h]

    ; FPRegs
    movsd   xmm0, qword ptr [r12+38h]
    movsd   xmm1, qword ptr [r12+40h]
    movsd   xmm2, qword ptr [r12+48h]
    movsd   xmm3, qword ptr [r12+50h]

    ; Win64 shadow space
    sub     rsp, 20h
    call    qword ptr [r12+10h]
    add     rsp, 20h

    ; result
    mov     qword ptr [r12+58h], rax

    mov     cl, byte ptr [r12+60h]
    cmp     cl, 8
    je      float_result
    cmp     cl, 9
    je      float_result
    ; FPC 3.2.2 Win64 returns Currency (resKind 10) as its scaled Int64
    ; value in RAX, already stored above.  Only Double and TDateTime use
    ; XMM0 on this compiler/dependency pin.
    jmp     result_done

float_result:
    movlpd  qword ptr [r12+58h], xmm0

result_done:

    ; Deliberately LEA, not "mov rsp,rbp":
    ; this is a legal Win64 unwind epilog.
    lea     rsp, [rbp]
    pop     r12
    pop     rbp
    ret

x64callmethod ENDP

END
