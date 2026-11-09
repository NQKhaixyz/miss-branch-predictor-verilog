# Unrolled weighted sum: 2 + 2*3 + 4*5 + 8*7 = 84. No conditional branches.
    lw    $1, 0($0)
    lw    $2, 4($0)
    lw    $3, 8($0)
    lw    $4, 12($0)
    sll   $2, $2, 1
    sll   $3, $3, 2
    sll   $4, $4, 3
    addu  $5, $1, $2
    addu  $5, $5, $3
    addu  $5, $5, $4
    sw    $5, 2048($0)
    nop
end:
