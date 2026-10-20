#!/usr/bin/env python3
"""Plot a tb-soak.sh run directory.

    tools/.venv/bin/python -I tools/plot-soak.py RUN_DIR [OUT_DIR]

Writes throughput.svg/png (5 s samples, replugs marked), temperature.svg/png,
rounds.svg/png (per-round fio bandwidth and p99 latency) and replug.svg/png
(recovery time per replug) to OUT_DIR (default RUN_DIR/graphs).
"""
import csv
import glob
import json
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

run = sys.argv[1]
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(run, "graphs")
os.makedirs(out, exist_ok=True)
name = os.path.basename(os.path.normpath(run))


def save(fig, stem):
    fig.tight_layout()
    for ext in ("svg", "png"):
        fig.savefig(os.path.join(out, f"{stem}.{ext}"), dpi=120)
    plt.close(fig)


events = list(csv.DictReader(open(os.path.join(run, "events.csv"))))
t0 = int(events[0]["epoch"])
ev = lambda kind: [e for e in events if e["event"] == kind]  # noqa: E731
minutes = lambda t: (int(t) - t0) / 60  # noqa: E731


def mark(ax):
    for e in ev("replug_start"):
        ax.axvline(minutes(e["epoch"]), color="tab:red", lw=0.8, ls="--")
    starts, oks = ev("round_start"), ev("round_ok")
    for s, o in zip(starts, oks):
        ax.axvspan(minutes(s["epoch"]), minutes(o["epoch"]), color="0.92", lw=0)


# throughput from cumulative sector counters (reset when the disk re-appears)
rows = list(csv.DictReader(open(os.path.join(run, "metrics.csv"))))
tx, rd, wr, tt, tv = [], [], [], [], []
prev = None
for r in rows:
    if r["temp_mC"]:
        tt.append(minutes(r["epoch"]))
        tv.append(int(r["temp_mC"]) / 1000)
    if not r["rd_sectors"]:
        prev = None
        continue
    cur = (int(r["epoch"]), r["disk"], int(r["rd_sectors"]), int(r["wr_sectors"]))
    if prev and prev[1] == cur[1] and cur[2] >= prev[2] and cur[3] >= prev[3]:
        dt = cur[0] - prev[0]
        if dt > 0:
            tx.append(minutes(cur[0]))
            rd.append((cur[2] - prev[2]) * 512 / dt / 2**20)
            wr.append((cur[3] - prev[3]) * 512 / dt / 2**20)
    prev = cur

fig, ax = plt.subplots(figsize=(11, 4))
mark(ax)
ax.plot(tx, rd, lw=0.8, label="read")
ax.plot(tx, wr, lw=0.8, label="write")
ax.set(xlabel="minutes", ylabel="MiB/s (5 s average)",
       title=f"TB NVMe soak {name}: throughput (grey = fio rounds, red = replug)")
ax.legend(loc="upper right")
save(fig, "throughput")

fig, ax = plt.subplots(figsize=(11, 3))
mark(ax)
ax.plot(tt, tv, color="tab:orange", lw=0.8)
ax.set(xlabel="minutes", ylabel="°C", title="NVMe composite temperature")
save(fig, "temperature")

# per-round fio results
per = {}
rounds = [(int(m.group(1)), f) for f in glob.glob(os.path.join(run, "fio-r*.json"))
          if (m := re.search(r"fio-r(\d+)\.json$", f))]
for rnd, f in sorted(rounds):
    try:
        jobs = json.load(open(f))["jobs"]
    except (ValueError, KeyError):
        continue
    for j in jobs:
        for d in ("read", "write"):
            if j[d]["io_bytes"]:
                key = f"{j['jobname']} {d}"
                p99 = j[d].get("clat_ns", {}).get("percentile", {}).get("99.000000", 0)
                per.setdefault(key, []).append((rnd, j[d]["bw"] / 1024, p99 / 1e6))
if per:
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4))
    for k, v in per.items():
        a1.plot([x[0] for x in v], [x[1] for x in v], marker="o", ms=3, label=k)
        a2.plot([x[0] for x in v], [x[2] for x in v], marker="o", ms=3, label=k)
    a1.set(xlabel="round", ylabel="MiB/s", title="fio bandwidth per round")
    a2.set(xlabel="round", ylabel="ms", title="p99 completion latency", yscale="log")
    a1.legend(fontsize=7)
    save(fig, "rounds")

back = [float(e["detail"]) for e in ev("replug_back")]
if back:
    fig, ax = plt.subplots(figsize=(6, 3))
    ax.bar(range(1, len(back) + 1), back)
    ax.set(xlabel="replug #", ylabel="s", title="Partition back after software replug")
    save(fig, "replug")

summary = open(os.path.join(run, "summary.txt")).read().strip() if os.path.exists(
    os.path.join(run, "summary.txt")) else "(running)"
print(f"{name}: {summary}; graphs in {out}")
