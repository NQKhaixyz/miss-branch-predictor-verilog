# Search 64 words for 136. Found at zero-based index 43; -1 if absent.
    addiu $1, $0, 0
    addiu $2, $0, 0
    addiu $3, $0, 136
    addiu $4, $0, 256
search:
    lw    $5, 0($1)
    beq   $5, $3, found
    addiu $2, $2, 1
    addiu $1, $1, 4
    bne   $1, $4, search
    addiu $2, $0, -1
found:
    sw    $2, 2048($0)
    nop
end:
