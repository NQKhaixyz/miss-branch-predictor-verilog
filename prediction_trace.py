"""Check fetch and training against an independent software predictor model."""

from collections import Counter, defaultdict


BRANCH_FIELDS = (
    "branches", "taken", "btb_hits", "raw_direction_misses",
    "effective_direction_misses", "next_pc_misses",
    "wrong_pc_direction", "wrong_pc_btb_miss", "wrong_pc_target",
)
PC_MASK = 0xFFFFFFFF


def verify_prediction_trace(output, totals, instructions, mode, index_bits):
    fetches = []
    resolves = {}
    for line in output.splitlines():
        tag, _, fields = line.partition(" ")
        if tag not in ("FETCH", "RESOLVE"):
            continue
        try:
            cycle, *record = map(int, fields.split())
        except ValueError as error:
            raise RuntimeError(f"Malformed prediction trace: {line}") from error
        if len(record) != 7:
            raise RuntimeError(f"Incomplete prediction trace: {line}")
        if tag == "FETCH":
            fetches.append((cycle, record))
        elif cycle not in resolves:
            resolves[cycle] = record
        else:
            raise RuntimeError(f"Cycle {cycle}: duplicate EX resolution")

    if len(fetches) != totals["cycles"] or len(resolves) != totals["branches"]:
        raise RuntimeError("Prediction trace length disagrees with the CPU counters")

    entries = 1 << index_bits
    initial_state = 1 if mode == 3 else 0
    taken_threshold = 2 if mode == 3 else 1
    counters = [initial_state] * entries
    btb = {}
    per_pc = defaultdict(Counter)
    expected_pc = 0
    in_id = in_ex = None
    for expected_cycle, (cycle, record) in enumerate(fetches, 1):
        pc, raw, hit, taken, next_pc, flush, stall = record
        if cycle != expected_cycle or pc != expected_pc:
            raise RuntimeError(
                f"Cycle {cycle}: fetch PC {pc:#010x}, expected {expected_pc:#010x} at cycle {expected_cycle}"
            )

        slot = (pc // 4) % entries
        stored_pc, target = btb.get(slot, (-1, 0))
        expected_raw = int(counters[slot] >= taken_threshold)
        expected_hit = int(stored_pc == pc)
        expected_taken = expected_raw & expected_hit
        fallthrough = (pc + 4) & PC_MASK
        expected_next = target if expected_taken else fallthrough
        prediction = (pc, expected_raw, expected_hit, expected_taken, expected_next)
        if (pc, raw, hit, taken, next_pc) != prediction:
            raise RuntimeError(
                f"Cycle {cycle}, IF at {pc:#010x}: observed {(raw, hit, taken, next_pc)}, "
                f"expected {prediction[1:]} (raw, hit, taken, next PC)"
            )

        event = resolves.pop(cycle, None)
        wrong_pc = False
        if event is not None:
            branch_pc, actual, ex_raw, ex_hit, ex_taken, ex_next, actual_next = event
            if (branch_pc, ex_raw, ex_hit, ex_taken, ex_next) != in_ex:
                raise RuntimeError(f"Cycle {cycle}: EX did not retain the prediction captured in IF")

            # Derive the fixed target from the instruction image even when the
            # branch did not take it. The RTL does not supply this reference.
            word = instructions[branch_pc // 4]
            offset = (word & 0xFFFF) - (0x10000 if word & 0x8000 else 0)
            target = (branch_pc + 4 + offset * 4) & PC_MASK
            wrong_pc = ex_next != actual_next
            row = per_pc[branch_pc]
            row["branches"] += 1
            row["taken"] += actual
            row["btb_hits"] += ex_hit
            row["raw_direction_misses"] += ex_raw != actual
            row["effective_direction_misses"] += ex_taken != actual
            row["next_pc_misses"] += wrong_pc
            if wrong_pc:
                if ex_raw != actual:
                    row["wrong_pc_direction"] += 1
                elif not ex_hit:
                    row["wrong_pc_btb_miss"] += 1
                else:
                    row["wrong_pc_target"] += 1

            # The lookup above observes state before this edge's training.
            if mode in (2, 3):
                update_slot = (branch_pc // 4) % entries
                btb[update_slot] = (branch_pc, target)
                counters[update_slot] = (
                    actual if mode == 2 else max(0, min(3, counters[update_slot] + (1 if actual else -1)))
                )

        if flush != wrong_pc:
            raise RuntimeError(f"Cycle {cycle}: flush does not match the verified EX prediction")
        if flush:
            expected_pc = actual_next
            in_id = in_ex = None
        elif stall:
            expected_pc = pc
            in_ex = None
        else:
            expected_pc = expected_next
            in_ex, in_id = in_id, prediction

    sums = Counter()
    for row in per_pc.values():
        sums.update(row)
    branches = totals["branches"]
    if resolves or any((
        sums["branches"] != branches,
        sums["btb_hits"] != totals["btb_hits"],
        branches - sums["raw_direction_misses"] != totals["dir_correct"],
        branches - sums["effective_direction_misses"] != totals["effective_correct"],
        branches - sums["next_pc_misses"] != totals["next_pc_correct"],
        sums["next_pc_misses"] != totals["flushes"],
    )):
        raise RuntimeError("Per-PC branch data disagrees with the CPU counters")

    return [
        {"pc": f"0x{pc:08x}", **{field: row[field] for field in BRANCH_FIELDS}}
        for pc, row in sorted(per_pc.items())
    ]
