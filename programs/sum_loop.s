# Sum the integers from 1 to 100. Result = 5050.
    addiu $1, $0, 100
    addiu $2, $0, 0
loop:
    addu  $2, $2, $1
    addiu $1, $1, -1
    bne   $1, $0, loop
    sw    $2, 2048($0)
    nop
end:
