#!/usr/bin/env python3
"""Parse DC sweep reports: Fmax curve, stage bucketing of endpoints."""
import re, sys, glob, os

REP = "reports"

def stage_of(leaf: str) -> str:
    base = re.sub(r"__?\d+_", "", leaf)  # strip _N_ / __N_ bus escapes only
    base = base.replace("_reg", "")
    if base.startswith("r5_"): return "S5_pack"
    if base.startswith("r4_lane"): return "S4_lane"
    if base.startswith("r4a_"): return "S4a"   # retiming may create r4a-style names (n/a here)
    if base.startswith("r4_"): return "S4_round"
    if base.startswith("r3a_lane"): return "S3a_lane"
    if base.startswith("r3a_"): return "S3a_scalar"
    if base.startswith("r3_lane"): return "S3_lane"
    if base.startswith("r3_"): return "S3_norm"
    if base.startswith("r2_tile"): return "S2_mul"
    if base.startswith("r2_lane"): return "S1_unpack"
    if base.startswith("r2_"): return "S1x2_passthru"
    if base.startswith("r1_lane"): return "S1_unpack"
    if base.startswith("r1_"): return "S1_unpack"
    return "OUT"

def parse_summary():
    rows = []
    if not os.path.exists(f"{REP}/sweep_summary.txt"):
        return rows
    with open(f"{REP}/sweep_summary.txt") as f:
        for line in f:
            m = re.match(r"PERIOD\s+([\d.]+)\s+WNS\s+(-?[\d.eE+-]+)\s+AREA\s*(\S*)", line)
            if m:
                p = float(m.group(1)); w = float(m.group(2))
                a = float(m.group(3)) if m.group(3) else None
                rows.append((p, w, a))
    return rows

def parse_endpoints(tag):
    out = []
    path = f"{REP}/endpoints_{tag}.rpt"
    if not os.path.exists(path):
        return out
    cur = None
    with open(path) as f:
        for line in f:
            s = line.rstrip()
            m1 = re.match(r"^(\S+/D)\s*\(([A-Z0-9_]+)\)\s*$", s)
            if m1:
                cur = m1.group(1)
                continue
            m2 = re.match(r"^\s+([\d.]+)\s*([rf]?)\s+([\d.]+)\s+(-?[\d.]+)\s*$", s)
            if m2 and cur:
                slack = float(m2.group(4))
                out.append((slack, stage_of(cur.split("/")[0])))
                cur = None
    return out

def area_from_report(tag):
    path = f"{REP}/area_{tag}.rpt"
    if not os.path.exists(path):
        return None, None
    area = cells = None
    with open(path) as f:
        for line in f:
            m = re.search(r"Total cell area:\s+([\d.]+)", line)
            if m: area = float(m.group(1))
            m = re.search(r"Number of cells:\s+(\d+)", line)
            if m: cells = int(m.group(1))
    return area, cells

def main():
    rows = parse_summary()
    print("=== sweep curve ===")
    print(f"{'period(ns)':>10} {'Fmax(MHz)':>10} {'WNS(ns)':>10} {'area(um2)':>12} {'cells':>7}")
    for p, wns, area in rows:
        if p >= 1.0:
            tag = "p1000"
        else:
            tag = "p" + f"{p:.2f}".replace(".", "").zfill(3)
        a, c = area_from_report(tag)
        if a is None: a = area
        if a is None:
            a_s = "n/a"
        else:
            a_s = f"{a:>12.1f}"
        c_s = f"{c:>7}" if c is not None else f"{'n/a':>7}"
        print(f"{p:>10.2f} {1000/p:>10.1f} {wns:>10.3f} {a_s} {c_s}")
    if rows:
        best = [r for r in rows if r[1] >= 0]
        if best:
            p, wns, area = best[-1]
            print(f"last WNS>=0: period={p}ns -> Fmax>={1000/p:.1f} MHz")
        # Fmax from worst point: fmax = 1/(period - wns)
        p, wns, area = rows[-1]
        print(f"est Fmax at last point: 1/({p}-({wns})) = {1000/(p-wns):.1f} MHz")
    print()
    tags = sorted(os.path.basename(f).replace("endpoints_","").replace(".rpt","")
                  for f in glob.glob(f"{REP}/endpoints_*.rpt"))
    if not tags:
        return
    for tag in tags:
        ep = parse_endpoints(tag)
        print(f"=== endpoint bucketing @ {tag} ({len(ep)} paths) ===")
        if ep:
            buckets = {}
            for slack, stage in ep:
                buckets.setdefault(stage, []).append(slack)
            print(f"{'stage':>16} {'#paths':>7} {'worst slack':>12} {'mean slack':>12}")
            for stage in sorted(buckets, key=lambda s: min(buckets[s])):
                sl = sorted(buckets[stage])
                print(f"{stage:>16} {len(sl):>7} {sl[0]:>12.3f} {sum(sl)/len(sl):>12.3f}")

if __name__ == "__main__":
    main()
