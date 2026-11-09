# Branches at 0x00c and 0x10c share indices for 16/64 entries but not 256.
# First branch usually taken, second always not taken. Result = 79.
    addiu $1, $0, 80
    addiu $2, $0, 0
loop:
    addiu $1, $1, -1
site_a:
    bne   $1, $0, site_b
    sw    $2, 2048($0)
    beq   $0, $0, finish
    sw    $1, 2044($0)

    .org 0x10c
site_b:
    bne   $0, $0, wrong_b
    addiu $2, $2, 1
    beq   $0, $0, loop
wrong_b:
    sw    $2, 2044($0)
finish:
    nop
end:
