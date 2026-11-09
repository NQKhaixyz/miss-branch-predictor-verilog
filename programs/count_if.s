# Count nonzero words in 96 elements arranged in blocks of 8 zeros + 4 nonzeros.
    addiu $1, $0, 0
    addiu $2, $0, 384
    addiu $3, $0, 0
loop:
    lw    $4, 0($1)
    beq   $4, $0, skip
    addiu $3, $3, 1
skip:
    addiu $1, $1, 4
    bne   $1, $2, loop
    sw    $3, 2048($0)
    nop
end:
