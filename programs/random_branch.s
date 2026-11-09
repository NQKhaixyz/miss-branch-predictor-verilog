# Count ones in 256 reproducible bits generated using seed 20261109.
    addiu $1, $0, 0
    addiu $2, $0, 1024
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
