"""Assemble the experiment workloads and produce independent ISA reference traces."""

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import random
import re


MEM_WORDS = 1024
ILLEGAL_WORD = 0xFFFFFFFF
RESULT_ADDR = 2048
WRONG_PATH_ADDR = 2044
WRONG_PATH_SENTINEL = 0x5A5AA5A5
RANDOM_BRANCH_SEED = 20261109
MIXED_RANDOM_SEED = 0x20261109
SOURCE_DIR = Path(__file__).resolve().parent

BENCHMARKS = (
    "sum_loop", "nested_loops", "count_if", "linear_search", "alternating",
    "random_branch", "branchless",
)
DIRECTED_CASES = ("hazards_flush", "aliasing", "zero_offset", "mixed_random")
CASE_NAMES = BENCHMARKS + DIRECTED_CASES

R_FUNCTIONS = {"addu": 0x21, "subu": 0x23, "slt": 0x2A}
I_OPCODES = {"addiu": 9, "lw": 0x23, "sw": 0x2B, "beq": 4, "bne": 5}
LABEL = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


@dataclass
class Execution:
    trace: list[tuple[int, int, int, int, int, int, int]]
    branches: list[tuple[int, int, int]]
    registers: list[int]
    memory: list[int]


def register(token: str) -> int:
    if re.fullmatch(r"\$[0-9]+", token):
        index = int(token[1:])
        if 0 <= index < 32:
            return index
    raise ValueError(f"invalid register {token!r}")


def signed16(value: int) -> int:
    if not -32768 <= value <= 32767:
        raise ValueError(f"signed 16-bit immediate out of range: {value}")
    return value & 0xFFFF


def encode(line: str, pc: int, labels: dict[str, int]) -> int:
    mnemonic, *args = re.split(r"[\s,()]+", line.rstrip(")"))
    if mnemonic == "nop" and not args:
        return 0
    if mnemonic in R_FUNCTIONS:
        rd, rs, rt = map(register, args)
        return (rs << 21) | (rt << 16) | (rd << 11) | R_FUNCTIONS[mnemonic]
    if mnemonic == "sll":
        dest, src, amount = args
        shift = int(amount, 0)
        if not 0 <= shift <= 31:
            raise ValueError(f"invalid shift amount {shift}")
        return (register(src) << 16) | (register(dest) << 11) | (shift << 6)
    if mnemonic not in I_OPCODES:
        raise ValueError(f"unknown instruction {mnemonic!r}")
    first, second, third = args
    if mnemonic in {"beq", "bne"}:
        rs, rt = register(first), register(second)
        immediate = (labels[third] - (pc + 4)) // 4 if third in labels else int(third, 0)
    elif mnemonic in {"lw", "sw"}:
        rt, rs = register(first), register(third)
        immediate = int(second, 0)
    else:
        rt, rs = register(first), register(second)
        immediate = int(third, 0)
    return (I_OPCODES[mnemonic] << 26) | (rs << 21) | (rt << 16) | signed16(immediate)


def assemble(source: str) -> tuple[list[int], int]:
    """Two-pass assembler for the nine instructions, labels, nop and .org."""
    pc = 0
    labels: dict[str, int] = {}
    instructions = []
    for number, original in enumerate(source.splitlines(), 1):
        line = original.split("#", 1)[0].strip()
        if ":" in line:
            label, line = (part.strip() for part in line.split(":", 1))
            if not LABEL.fullmatch(label) or label in labels:
                raise ValueError(f"line {number}: invalid or duplicate label {label!r}")
            labels[label] = pc
        if not line:
            continue
        if line.startswith(".org "):
            address = int(line[5:].strip(), 0)
            if address < pc or address % 4 or address >= MEM_WORDS * 4:
                raise ValueError(f"line {number}: invalid .org address")
            pc = address
            continue
        if pc >= MEM_WORDS * 4:
            raise ValueError(f"line {number}: program exceeds instruction memory")
        instructions.append((pc, number, line))
        pc += 4

    if not instructions or labels.get("end") != pc:
        raise ValueError("program must end with an exclusive end: label")
    image = [ILLEGAL_WORD] * MEM_WORDS
    for address, number, line in instructions:
        try:
            image[address // 4] = encode(line, address, labels)
        except ValueError as error:
            raise ValueError(f"line {number}: {line}: {error}") from error
    return image, pc


def u32(value: int) -> int:
    return value & 0xFFFFFFFF


def signed(value: int, bits: int) -> int:
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def word_index(address: int) -> int:
    if address % 4 or not 0 <= address < MEM_WORDS * 4:
        raise ValueError(f"unaligned or out-of-range address 0x{address:08x}")
    return address // 4


def execute(imem: list[int], initial_dmem: list[int], end_pc: int) -> Execution:
    """Sequentially interpret binary MIPS instructions without pipeline state."""
    regs = [0] * 32
    memory = initial_dmem.copy()
    pc = 0
    trace = []
    branches = []
    while pc != end_pc:
        if len(trace) >= 100_000:
            raise ValueError("reference program did not terminate within 100000 instructions")
        insn = imem[word_index(pc)]
        op, rs, rt = insn >> 26, (insn >> 21) & 31, (insn >> 16) & 31
        source, second = regs[rs], regs[rt]
        next_pc = pc + 4
        dest = value = mem_we = mem_addr = mem_value = 0
        if op == 0:
            dest, shamt, funct = (insn >> 11) & 31, (insn >> 6) & 31, insn & 63
            if funct == 0x00 and rs == 0:
                value = second << shamt
            elif funct == 0x21 and shamt == 0:
                value = source + second
            elif funct == 0x23 and shamt == 0:
                value = source - second
            elif funct == 0x2A and shamt == 0:
                value = int(signed(source, 32) < signed(second, 32))
            else:
                raise ValueError(f"unsupported R-type word 0x{insn:08x} at 0x{pc:08x}")
        else:
            imm = signed(insn & 0xFFFF, 16)
            if op == 9:
                dest, value = rt, source + imm
            elif op == 0x23:
                dest = rt
                value = memory[word_index(u32(source + imm))]
            elif op == 0x2B:
                mem_we, mem_addr, mem_value = 1, u32(source + imm), second
                memory[word_index(mem_addr)] = mem_value
            elif op in {4, 5}:
                equal = source == second
                taken = equal if op == 4 else not equal
                if taken:
                    next_pc = u32(next_pc + 4 * imm)
                branches.append((pc, int(taken), next_pc))
            else:
                raise ValueError(f"unsupported word 0x{insn:08x} at 0x{pc:08x}")

        if dest:
            value = u32(value)
            regs[dest] = value
        else:
            value = 0
        trace.append((pc, int(bool(dest)), dest, value, mem_we, mem_addr, mem_value))
        pc = next_pc
    return Execution(trace, branches, regs, memory)


def mixed_random_source() -> str:
    rng = random.Random(MIXED_RANDOM_SEED)
    lines = [f"# Generated stress program, seed {MIXED_RANDOM_SEED:#x}."]
    lines.extend(f"lw ${reg}, {4 * reg}($0)" for reg in range(1, 16))
    lines.extend(("addiu $16, $0, 6", "addiu $17, $0, 0", "loop:"))
    for block in range(24):
        for step in range(8):
            rd, rs, rt = (rng.randrange(16) for _ in range(3))
            mnemonic = rng.choice(("addu", "subu", "slt", "sll", "addiu", "lw", "sw"))
            if mnemonic in R_FUNCTIONS:
                lines.append(f"{mnemonic} ${rd}, ${rs}, ${rt}")
            elif mnemonic == "sll":
                lines.append(f"sll ${rd}, ${rs}, {rng.randrange(32)}")
            elif mnemonic == "addiu":
                lines.append(f"addiu ${rd}, ${rs}, {rng.randrange(-32768, 32768)}")
            else:
                lines.append(f"{mnemonic} ${rd}, {4 * rng.randrange(32)}($0)")
            if step == 4:
                branch = "beq" if block % 2 else "bne"
                lines.append(f"{branch} ${rd}, ${rt}, skip_{block}")
        lines.append(f"skip_{block}:")
    lines.extend(("addiu $17, $17, 1", "addiu $16, $16, -1", "bne $16, $0, loop",
                  "sw $17, 2048($0)", "sw $8, 2052($0)", "nop", "end:"))
    return "\n".join(lines) + "\n"


def case_inputs(name: str) -> tuple[str, list[int], int]:
    if name not in CASE_NAMES:
        raise ValueError(f"unknown program {name!r}")
    data = [0] * MEM_WORDS
    if name == "mixed_random":
        source = mixed_random_source()
    else:
        source = (SOURCE_DIR / f"{name}.s").read_text(encoding="utf-8")

    expected = {
        "sum_loop": 5050, "nested_loops": 1680, "count_if": 32, "linear_search": 43,
        "alternating": 64, "branchless": 84, "hazards_flush": 61, "aliasing": 79,
        "zero_offset": 40, "mixed_random": 6,
    }
    if name == "count_if":
        data[:96] = [index + 1 if index % 12 >= 8 else 0 for index in range(96)]
    elif name == "linear_search":
        data[:64] = [7 + 3 * index for index in range(64)]
    elif name == "alternating":
        data[:128] = [0, 1] * 64
    elif name == "random_branch":
        rng = random.Random(RANDOM_BRANCH_SEED)
        data[:256] = [rng.getrandbits(1) for _ in range(256)]
        expected[name] = sum(data[:256])
    elif name == "branchless":
        data[:4] = [2, 3, 5, 7]
    elif name in {"hazards_flush", "aliasing"}:
        data[WRONG_PATH_ADDR // 4] = WRONG_PATH_SENTINEL
    elif name == "mixed_random":
        rng = random.Random(MIXED_RANDOM_SEED ^ 0xBADC0DE)
        data[:32] = [rng.getrandbits(32) for _ in range(32)]
    return source, data, expected[name]


def write_words(path: Path, words: list[int]) -> None:
    path.write_text("".join(f"{word:08x}\n" for word in words), encoding="ascii")


def generate_case(name: str, output_dir: Path) -> dict:
    """Write generated files for one case into the supplied directory."""
    source, dmem, expected = case_inputs(name)
    imem, end_pc = assemble(source)
    execution = execute(imem, dmem, end_pc)
    result = execution.memory[RESULT_ADDR // 4]
    if result != expected:
        raise ValueError(f"{name}: expected known result {expected}, reference returned {result}")
    if name in {"hazards_flush", "aliasing"}:
        if execution.memory[WRONG_PATH_ADDR // 4] != WRONG_PATH_SENTINEL:
            raise ValueError(f"{name}: reference modified the wrong-path sentinel")

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "source.s").write_text(source, encoding="utf-8")
    write_words(output_dir / "imem.hex", imem)
    write_words(output_dir / "dmem.hex", dmem)
    write_words(output_dir / "final_dmem.hex", execution.memory)
    write_words(output_dir / "final_regs.hex", execution.registers)
    (output_dir / "trace.hex").write_text(
        "".join(f"{pc:08x} {we:x} {rd:02x} {value:08x} {mwe:x} {addr:08x} {data:08x}\n"
                for pc, we, rd, value, mwe, addr, data in execution.trace),
        encoding="ascii",
    )
    (output_dir / "branches.hex").write_text(
        "".join(f"{pc:08x} {taken:x} {next_pc:08x}\n" for pc, taken, next_pc in execution.branches),
        encoding="ascii",
    )
    metadata = {
        "name": name,
        "kind": "benchmark" if name in BENCHMARKS else "directed",
        "instructions": len(execution.trace),
        "branches": len(execution.branches),
        "end_pc": end_pc,
        "result": result,
        "result_address": RESULT_ADDR,
    }
    if name == "random_branch":
        metadata["seed"] = RANDOM_BRANCH_SEED
    elif name == "mixed_random":
        metadata["seed"] = MIXED_RANDOM_SEED
    (output_dir / "meta.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="ascii")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/programs"))
    parser.add_argument("--case", choices=CASE_NAMES, action="append", help="repeat to select cases")
    parser.add_argument("--list", action="store_true", help="list available program IDs")
    args = parser.parse_args()
    if args.list:
        print("\n".join(CASE_NAMES))
        return
    for name in args.case or CASE_NAMES:
        info = generate_case(name, args.out / name)
        print(f"{name}: {info['instructions']} instructions, {info['branches']} branches, "
              f"result={info['result']}")


if __name__ == "__main__":
    main()
