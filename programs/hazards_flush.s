# Forwarding to BEQ, load-use stalls, wrong-path store/branch, signed SLT,
# ALU and load forwarding to stores, ignoring writes to r0, and a backward branch.
    addiu $1, $0, 23
    addiu $11, $0, 23
    beq   $11, $1, after_alu
    sw    $1, 2044($0)
    bne   $1, $0, failed
after_alu:
    sw    $1, 0($0)
    lw    $2, 0($0)
    beq   $2, $1, after_load
    sw    $1, 2044($0)
    bne   $1, $0, failed
after_load:
    addiu $3, $0, 2
loop:
    addiu $3, $3, -1
    bne   $3, $0, loop
    lw    $4, 0($0)
    sw    $4, 8($0)
    addiu $5, $0, 12
    lw    $6, -4($5)
    addiu $7, $6, -30
    slt   $8, $7, $0
    addu  $0, $1, $6
    subu  $9, $6, $7
    sll   $10, $9, 1
    addu  $10, $10, $8
    sw    $10, 2048($0)
    beq   $0, $0, finish
    sw    $10, 2044($0)
failed:
    sw    $0, 2048($0)
finish:
    nop
end:
