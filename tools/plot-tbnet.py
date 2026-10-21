#!/usr/bin/env python3
"""Draw the thunderbolt-net throughput chart in the README.

    python3 tools/plot-tbnet.py [OUT_DIR]

Writes tb-net-throughput-light.svg and tb-net-throughput-dark.svg to OUT_DIR
(default docs/images). The numbers are the README's "Thunderbolt networking"
measurements: iperf3, single stream, M1 Max, 20 Gb/s x2 USB4 link.
"""
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "docs", "images")
os.makedirs(out, exist_ok=True)

# (step, what changed, Gb/s, label, group, frames lost)
# group "loop": one Mac Studio, cable between two of its ports (one end in a
# network namespace); "m2m": between two Macs.
STEPS = [
    ("Unpatched", "non-coherent NHI", 3.4, "3.4", "loop", True),
    ("+ DMA-coherent NHI", "patch 3", 4.2, "4.2", "loop", True),
    ("+ Tx E2E flow control", "patches 1-2", 4.8, "4.8", "loop", False),
    ("+ RX ring 1024, threaded NAPI, GRO off", "tuning", 8.2, "8.2", "loop", False),
    ("+ RX page pool, lost-wakeup fix", "patches 4-5, ring 256", 21.2, "21.2", "loop", False),
    ("Mac Studio to MacBook Pro", "patch 6, MTU 1500", 21.4, "21.4", "m2m", False),
    ("Forwarded by a bridge to MTU 1500", "patch 7 (was 0.01 Gb/s)", 19.5, "19.1-19.5", "m2m", False),
]
# CPU taken by the whole loopback at a fixed 5 Gb/s single stream
CPU = [("before patch 5", 0.86), ("with patch 5", 0.40)]

THEMES = {
    "light": dict(fg="#0b0b0b", fg2="#52514e", muted="#898781", grid="#e1e0d9",
                  loop="#2a78d6", m2m="#1baf7a", surface="#fcfcfb"),
    "dark": dict(fg="#f0efec", fg2="#c3c2b7", muted="#898781", grid="#2c2c2a",
                 loop="#3987e5", m2m="#199e70", surface="#1a1a19"),
}


def draw(name, t):
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "svg.fonttype": "none", "hatch.linewidth": 0.8})
    fig, (ax, ax2) = plt.subplots(
        1, 2, figsize=(11, 4.9), gridspec_kw={"width_ratios": [3.3, 1], "wspace": 0.08})
    fig.patch.set_alpha(0)
    for a in (ax, ax2):
        a.patch.set_alpha(0)
        for s in ("top", "right", "left"):
            a.spines[s].set_visible(False)
        a.spines["bottom"].set_color(t["grid"])
        a.tick_params(colors=t["muted"], length=0)
        a.xaxis.grid(True, color=t["grid"], lw=0.8)
        a.set_axisbelow(True)

    y = list(range(len(STEPS)))[::-1]
    for yi, (step, what, v, lab, grp, lossy) in zip(y, STEPS):
        ax.barh(yi, v, height=0.62, color=t[grp], edgecolor=t["surface"] if lossy else "none",
                hatch="////" if lossy else None, lw=0)
        ax.text(v + 0.35, yi, lab + " Gb/s", va="center", color=t["fg"], fontsize=10,
                fontweight="bold")
        if lossy:
            ax.text(v + 3.3, yi, "frames lost", va="center",
                    color=t["muted"], fontsize=9, style="italic")
    ax.set_yticks(y)
    ax.set_yticklabels([""] * len(y))
    for yi, (step, what, *_rest) in zip(y, STEPS):
        ax.text(-0.4, yi + 0.13, step, ha="right", va="center", color=t["fg"], fontsize=10)
        ax.text(-0.4, yi - 0.2, what, ha="right", va="center", color=t["fg2"], fontsize=8.5)
    ax.set_xlim(0, 26)
    ax.set_xlabel("Gb/s, single TCP stream (iperf3)", color=t["fg2"])
    ax.axhline(1.5, color=t["grid"], lw=1, ls=(0, (3, 3)))
    ax.set_title("thunderbolt-net throughput, M1 Max, USB4 20 Gb/s x2", loc="left",
                 color=t["fg"], fontsize=12, fontweight="bold", x=-0.48, pad=30)
    ax.legend(handles=[Patch(color=t["loop"], label="one Mac, port to port"),
                       Patch(color=t["m2m"], label="between two Macs"),
                       Patch(facecolor=t["loop"], edgecolor=t["surface"], hatch="////",
                             label="frames lost (no flow control)")],
              loc="lower left", bbox_to_anchor=(-0.48, 1.0), ncol=3, frameon=False,
              labelcolor=t["fg2"], fontsize=9, handlelength=1.6, borderaxespad=0.2)

    labels = [c[0] for c in CPU]
    vals = [c[1] for c in CPU]
    ax2.bar([0, 1], vals, width=0.5, color=[t["muted"], t["loop"]])
    for x, v in zip([0, 1], vals):
        ax2.text(x, v + 0.02, f"{v:.2f}", ha="center", va="bottom", color=t["fg"],
                 fontweight="bold")
    ax2.set_xticks([0, 1])
    ax2.set_xticklabels(labels, color=t["fg2"], fontsize=9)
    ax2.set_ylim(0, 1.0)
    ax2.set_yticks([])
    ax2.xaxis.grid(False)
    ax2.yaxis.grid(True, color=t["grid"], lw=0.8)
    ax2.set_title("CPU at a fixed 5 Gb/s", color=t["fg"], fontsize=11,
                  fontweight="bold", pad=30)
    ax2.text(0.5, 1.03, "cores busy, whole loopback", transform=ax2.transAxes, ha="center",
             va="bottom", color=t["fg2"], fontsize=9)

    fig.subplots_adjust(left=0.27, right=0.985, top=0.83, bottom=0.12)
    path = os.path.join(out, f"tb-net-throughput-{name}.svg")
    fig.savefig(path, metadata={"Date": None, "Creator": None})
    if os.environ.get("PNG_PREVIEW"):
        fig.patch.set_alpha(1)
        fig.patch.set_facecolor(t["surface"])
        fig.savefig(os.path.join(os.environ["PNG_PREVIEW"], f"tb-net-{name}.png"), dpi=110,
                    facecolor=t["surface"])
    plt.close(fig)
    return path


for n, th in THEMES.items():
    print(draw(n, th))
