#!/usr/bin/env python3
"""Summarize `kitten __benchmark__` reports into a per-suite MB/s table.

Input: one or more <terminal>.kitten files captured by bench-vte-compare.sh
(the kitten prints its report to stdout while running the benchmark payload
through /dev/tty, so the capture contains only the report).

Report lines look like (ANSI-colored):
  Only ASCII chars         : 227.34ms   @ 88.0    MB/s
"""

from __future__ import annotations

import math
import re
import statistics
import sys
from pathlib import Path

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.")
# Durations render as "227.34ms", "24.81s", or "1m34.51s" depending on
# magnitude; only the MB/s figure is used.
LINE_RE = re.compile(r"^\s*(.+?)\s*:\s*([0-9hms.]+)\s*@\s*([0-9.]+)\s*MB/s\s*$")


def parse_kitten(path: Path) -> dict[str, float]:
    suites: dict[str, float] = {}
    for raw in path.read_text(errors="replace").splitlines():
        line = ANSI_RE.sub("", raw)
        m = LINE_RE.match(line)
        if m:
            suites[m.group(1)] = float(m.group(3))
    return suites


def geomean(values: list[float]) -> float:
    vals = [v for v in values if v > 0]
    if not vals:
        return float("nan")
    return math.exp(statistics.mean(math.log(v) for v in vals))


def main(argv: list[str]) -> int:
    paths = [Path(a) for a in argv[1:]]
    if not paths:
        print(f"usage: {sys.argv[0]} <terminal>.kitten ...", file=sys.stderr)
        return 2

    results: dict[str, dict[str, float]] = {}
    for p in paths:
        suites = parse_kitten(p)
        if suites:
            results[p.stem] = suites
        else:
            print(f"warning: no kitten results parsed from {p}", file=sys.stderr)

    if not results:
        print("no parseable kitten reports", file=sys.stderr)
        return 1

    terms = sorted(results)
    suite_names: list[str] = []
    for suites in results.values():
        for name in suites:
            if name not in suite_names:
                suite_names.append(name)

    name_w = max(len(s) for s in suite_names + ["geomean MB/s"]) + 2
    col_w = max(max(len(t) for t in terms) + 2, 10)

    header = "suite".ljust(name_w) + "".join(t.rjust(col_w) for t in terms)
    print(header)
    print("-" * len(header))
    for suite in suite_names:
        row = suite.ljust(name_w)
        for t in terms:
            v = results[t].get(suite)
            row += (f"{v:.1f}" if v is not None else "—").rjust(col_w)
        print(row)

    # Subset detection: suite speeds differ several-fold (long escape
    # codes parse 2-8× faster than CSI for every terminal measured), so a
    # geomean over fewer suites (kitten errored mid-run, truncated
    # capture) is inflated/deflated and not comparable. Asterisk and
    # report; exclude NaN (no positive values) from the ranking.
    subset_terms: dict[str, list[str]] = {}
    for t in terms:
        missing = [s for s in suite_names if s not in results[t]]
        if missing:
            subset_terms[t] = missing

    print()
    gms = {t: geomean(list(results[t].values())) for t in terms}
    row = "geomean MB/s".ljust(name_w)
    for t in terms:
        mark = "*" if t in subset_terms else ""
        cell = "—" if gms[t] != gms[t] else f"{gms[t]:.1f}{mark}"
        row += cell.rjust(col_w)
    print(row)

    print()
    print("ranking (higher = faster):")
    rankable = {t: g for t, g in gms.items() if g == g}
    for t in gms:
        if t not in rankable:
            print(f"  (excluded {t}: no parseable positive MB/s values)",
                  file=sys.stderr)
    for i, (t, g) in enumerate(sorted(rankable.items(), key=lambda kv: -kv[1]), 1):
        mark = "*" if t in subset_terms else ""
        print(f"  {i}. {t:<18} {g:.1f}{mark} MB/s")

    if subset_terms:
        print()
        print("  * geomean over a PARTIAL suite set — not comparable; "
              "investigate before citing:")
        for t, missing in sorted(subset_terms.items()):
            print(f"    {t}: missing {', '.join(missing)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
