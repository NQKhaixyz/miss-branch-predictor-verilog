"""Compile Verilog, verify architectural traces, and measure branch performance."""

import argparse
import csv
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
MODES = {0: "stall", 1: "always_nt", 2: "one_bit", 3: "two_bit", 4: "single_cycle"}
COUNTERS = (
    "cycles", "retired", "branches", "dir_correct", "effective_correct",
    "next_pc_correct", "btb_hits", "flushes", "load_stalls", "branch_stalls",
)


def command(args):
    args = [str(arg) for arg in args]
    proc = subprocess.run(
        args, cwd=ROOT, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=120,
    )
    if proc.returncode:
        raise RuntimeError(
            f"{subprocess.list2cmdline(args)}\n{proc.stdout}{proc.stderr}".strip()
        )
    return proc.stdout + proc.stderr


def simulator(directory):
    def find(name):
        location = shutil.which(name, path=str(directory) if directory else None)
        if not location:
            raise RuntimeError(
                f"Không tìm thấy {name}. Thêm thư mục bin của Icarus vào PATH "
                "hoặc truyền --iverilog-bin."
            )
        return Path(location).resolve()

    iverilog, vvp = find("iverilog"), find("vvp")
    # Icarus launches a backend process that must find DLLs beside the compiler.
    paths = list(dict.fromkeys(str(binary.parent) for binary in (iverilog, vvp)))
    os.environ["PATH"] = os.pathsep.join([*paths, os.environ.get("PATH", "")])
    return iverilog, vvp


def compile_tb(iverilog, work, top, **parameters):
    suffix = "".join(f"_{value}" for value in parameters.values())
    target = work / f"{top}{suffix}.vvp"
    overrides = [f"-P{top}.{key}={value}" for key, value in parameters.items()]
    files = sorted((ROOT / "rtl").glob("*.v"))
    command([
        iverilog, "-g2005", "-Wall", "-I", ROOT / "rtl",
        "-s", top, *overrides, "-o", target, *files, ROOT / "tb" / f"{top}.v",
    ])
    return target


def simulation(vvp, binary, case, meta, vcd=None):
    inputs = {
        "IMEM": "imem.hex", "DMEM": "dmem.hex", "TRACE": "trace.hex",
        "BRANCH": "branches.hex", "FINAL_DMEM": "final_dmem.hex",
    }
    args = [f"+{key}={case / filename}" for key, filename in inputs.items()]
    args.extend([
        f"+COUNT={meta['instructions']}",
        f"+MAX_CYCLES={4 * meta['instructions'] + 32}",
    ])
    if vcd:
        args.append(f"+VCD={vcd}")
    output = command([vvp, binary, *args])
    result = re.findall(r"^RESULT (.+)$", output, flags=re.MULTILINE)
    if len(result) != 1 or re.search(r"^ERROR:", output, flags=re.MULTILINE):
        raise RuntimeError(f"{case.name} / {binary.name}\n{output}")
    counters = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", result[0])}
    if set(COUNTERS) - counters.keys():
        raise RuntimeError(f"Thiếu bộ đếm trong kết quả\n{output}")
    return {key: counters[key] for key in COUNTERS}


def percentage(num, den):
    return round(100 * num / den, 4) if den else None


def measure(case, meta, mode, index_bits, counts, baseline, static):
    retired, branches, cycles = (counts[key] for key in ("retired", "branches", "cycles"))
    if retired != meta["instructions"] or (mode != 4 and branches != meta["branches"]):
        raise RuntimeError(f"{case} / {MODES[mode]} có số lệnh hoặc số nhánh sai.")
    if mode != 4:
        expected = retired + 4 + counts["load_stalls"] + counts["branch_stalls"] + 2 * counts["flushes"]
        if cycles != expected:
            raise RuntimeError(f"{case} / {MODES[mode]} đo {cycles} chu kỳ, mô hình đếm {expected}.")
    predicted = mode in (1, 2, 3)
    dynamic = mode in (2, 3)
    entries = 1 << index_bits if dynamic else 0
    return {
        "case": case,
        "kind": meta["kind"],
        "mode": MODES[mode],
        "entries": entries,
        **counts,
        "cpi": round(cycles / retired, 6),
        "raw_accuracy_pct": percentage(counts["dir_correct"], branches) if predicted else None,
        "direction_accuracy_pct": percentage(counts["effective_correct"], branches) if predicted else None,
        "next_pc_accuracy_pct": percentage(counts["next_pc_correct"], branches) if predicted else None,
        "btb_hit_rate_pct": percentage(counts["btb_hits"], branches) if dynamic else None,
        "speedup_vs_stall": round(baseline / cycles, 6) if mode != 4 else None,
        "cycle_reduction_vs_stall_pct": percentage(baseline - cycles, baseline) if mode != 4 else None,
        "speedup_vs_always_nt": round(static / cycles, 6) if mode != 4 else None,
        "cycle_reduction_vs_always_nt_pct": percentage(static - cycles, static) if mode != 4 else None,
    }


def run(args, work):
    iverilog, vvp = simulator(args.iverilog_bin)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    print(command([iverilog, "-V"]).splitlines()[0], flush=True)

    predictor = compile_tb(iverilog, work, "tb_predictor")
    check = command([vvp, predictor])
    if "PASS predictor" not in check or re.search(r"^ERROR:", check, re.MULTILINE):
        raise RuntimeError(check)
    print("PASS predictor", flush=True)

    cases_dir = work / "programs"
    generate_args = [arg for case in args.case for arg in ("--case", case)]
    command([sys.executable, ROOT / "programs" / "generate.py", "--out", cases_dir, *generate_args])
    cases = sorted(cases_dir.glob("*/meta.json"))
    if not cases:
        raise RuntimeError("Không có chương trình kiểm thử.")

    main_modes = [(0, 6), (1, 6), (2, 6), (3, 6), (4, 6)]
    sweep_modes = [] if args.no_sweep else [(mode, idx) for mode in (2, 3) for idx in (4, 8)]
    binaries = {
        (mode, idx): compile_tb(iverilog, work, "tb_cpu", MODE=mode, INDEX_BITS=idx)
        for mode, idx in main_modes + sweep_modes
    }
    rows = []
    for case in cases:
        meta = json.loads(case.read_text(encoding="utf-8"))
        name = case.parent.name
        metrics = {}
        modes = main_modes + (sweep_modes if meta["kind"] == "benchmark" or name == "aliasing" else [])
        for mode, idx in modes:
            vcd = None
            if name in args.wave and idx == 6 and mode in (0, 3):
                vcd = output / "waveforms" / f"{name}_{MODES[mode]}.vcd"
                vcd.parent.mkdir(exist_ok=True)
            metrics[mode, idx] = simulation(vvp, binaries[mode, idx], case.parent, meta, vcd)
        for (mode, idx), counts in metrics.items():
            rows.append(measure(
                name, meta, mode, idx, counts, metrics[0, 6]["cycles"], metrics[1, 6]["cycles"],
            ))
        print(f"PASS {name}: {len(metrics)} cấu hình, {meta['instructions']} lệnh", flush=True)

    with (output / "metrics.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    if not args.no_plot:
        from plot_results import plot
        plot(rows, output)
    print(f"Hoàn tất {len(rows)} lượt CPU, kết quả tại {output}", flush=True)


def main():
    for stream in (sys.stdout, sys.stderr):
        if not stream.isatty():
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", default=[], help="Chọn chương trình, có thể lặp.")
    parser.add_argument("--wave", action="append", default=None, help="Ghi VCD cho chương trình.")
    parser.add_argument("--no-sweep", action="store_true", help="Chỉ chạy cấu hình mặc định 64 mục.")
    parser.add_argument("--no-plot", action="store_true", help="Chỉ ghi CSV, không cần matplotlib.")
    parser.add_argument("--output", type=Path, default=ROOT / "results")
    parser.add_argument("--iverilog-bin", type=Path, default=os.environ.get("IVERILOG_BIN"))
    args = parser.parse_args()
    if args.wave is None:
        args.wave = ["sum_loop", "hazards_flush"]
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix="run_", dir=build) as work:
            run(args, Path(work))
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
