# Add each value from 20 down to 1 eight times. Result = 1680.
    addiu $1, $0, 20
    addiu $2, $0, 0
outer:
    addiu $3, $0, 8
inner:
    addu  $2, $2, $1
    addiu $3, $3, -1
    bne   $3, $0, inner
    addiu $1, $1, -1
    bne   $1, $0, outer
    sw    $2, 2048($0)
    nop
end:
