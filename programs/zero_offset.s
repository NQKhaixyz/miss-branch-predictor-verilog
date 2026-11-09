# A taken branch to PC+4 can get the direction wrong and the next PC right.
    addiu $1, $0, 40
    addiu $2, $0, 0
loop:
    beq   $1, $1, next
next:
    bne   $1, $1, after
after:
    addiu $2, $2, 1
    addiu $1, $1, -1
    bne   $1, $0, loop
    sw    $2, 2048($0)
    nop
end:
