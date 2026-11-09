"""Plot the measured CPU results with a non-interactive backend."""

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import PercentFormatter


CASES = {
    "sum_loop": "Tính tổng",
    "nested_loops": "Vòng lặp lồng",
    "count_if": "Đếm theo điều kiện",
    "linear_search": "Tìm kiếm tuyến tính",
    "alternating": "Nhánh xen kẽ",
    "random_branch": "Nhánh giả ngẫu nhiên",
    "branchless": "Không có nhánh",
}
MODES = {
    "always_nt": ("Luôn không rẽ", "#8291a6"),
    "one_bit": ("1 bit + BTB", "#4f71b8"),
    "two_bit": ("2 bit + BTB", "#007e71"),
}


def plot(rows, output):
    main = {(r["case"], r["mode"]): r for r in rows if r["entries"] in (0, 64)}
    cases = [case for case in CASES if (case, "two_bit") in main]
    if not cases:
        return

    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11})
    fig, axes = plt.subplots(1, 2, figsize=(12.0, 5.2), sharey=True)
    fig.suptitle("Dự đoán nhánh trên CPU MIPS pipeline 5 tầng", x=0.15, ha="left",
                 color="#142841", fontsize=18, fontweight="bold")

    for index, (mode, (label, color)) in enumerate(MODES.items()):
        points = [main[case, mode] for case in cases]
        ys = [y + (index - 1) * 0.22 for y in range(len(cases))]
        accuracy = [row["direction_accuracy_pct"] for row in points]
        valid = [(y, value) for y, value in zip(ys, accuracy) if value is not None]
        axes[0].barh([y for y, _ in valid], [value for _, value in valid],
                     height=0.19, color=color, label=label)
        axes[1].barh(ys, [row["speedup_vs_stall"] for row in points],
                     height=0.19, color=color)

    for axis in axes:
        axis.set_axisbelow(True)
        axis.grid(axis="x", color="#dee5ed", linewidth=0.7)
        axis.spines[["top", "right", "left"]].set_visible(False)
        axis.spines["bottom"].set_color("#bec8d3")
        axis.tick_params(axis="y", length=0)
    axes[0].set_yticks(range(len(cases)), [CASES[case] for case in cases])
    axes[0].invert_yaxis()
    axes[0].set_xlim(0, 100)
    axes[0].xaxis.set_major_formatter(PercentFormatter(100, decimals=0))
    axes[0].set_title("Độ chính xác hướng", loc="left", fontweight="bold")
    if "branchless" in cases:
        axes[0].text(3, cases.index("branchless"), "Không áp dụng", va="center", color="#506175")

    axes[1].axvline(1, color="#36495d", linestyle="--", linewidth=1)
    axes[1].set_title("Tăng tốc so với chờ nhánh", loc="left", fontweight="bold")
    axes[1].set_xlabel("Tỷ lệ chu kỳ (lần)")
    fig.legend(*axes[0].get_legend_handles_labels(), loc="lower left",
               bbox_to_anchor=(0.14, 0.015), ncol=3, frameon=False)
    fig.subplots_adjust(left=0.19, right=0.97, top=0.82, bottom=0.22, wspace=0.16)
    fig.savefig(output / "performance.png", dpi=170, facecolor="white")
    plt.close(fig)
