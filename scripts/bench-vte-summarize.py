#!/usr/bin/env python3
"""Summarize vtebench .dat files into a per-benchmark MB/s comparison table.

vtebench samples are per-1MB-chunk millisecond counts. MB/s = 1000 / median_ms.
"""

from __future__ import annotations

import statistics
import sys
from pathlib import Path


BYTES_PER_SAMPLE_MB = 1.0  # vtebench --min-bytes default is 1 MiB; close enough for MB/s.


def parse_dat(path: Path) -> dict[str, list[int]]:
    lines = path.read_text().splitlines()
    if not lines:
        return {}
    names = lines[0].split()
    cols: dict[str, list[int]] = {n: [] for n in names}
    for row in lines[1:]:
        toks = row.split()
        for name, tok in zip(names, toks):
            if tok == "_" or not tok:
                continue
            try:
                cols[name].append(int(tok))
            except ValueError:
                continue
    return cols


def mbps(samples_ms: list[int]) -> float:
    if not samples_ms:
        return float("nan")
    med = statistics.median(samples_ms)
    if med <= 0:
        return float("inf")
    return 1000.0 * BYTES_PER_SAMPLE_MB / med


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: bench-vte-summarize.py <dat> [<dat> ...]", file=sys.stderr)
        return 2

    # term_name -> benchmark -> samples
    per_term: dict[str, dict[str, list[int]]] = {}
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            print(f"(skip missing: {p})", file=sys.stderr)
            continue
        name = p.stem
        per_term[name] = parse_dat(p)

    if not per_term:
        print("no .dat files found", file=sys.stderr)
        return 1

    benches = sorted({b for t in per_term.values() for b in t.keys()})
    terms = sorted(per_term.keys())

    col_w = max(18, max((len(t) for t in terms), default=18))

    print(f"{'benchmark':<28}", end="")
    for t in terms:
        print(f"{t:>{col_w}}", end="")
    print()
    print("-" * (28 + col_w * len(terms)))

    # For each benchmark: print MB/s per terminal and rank.
    for b in benches:
        print(f"{b:<28}", end="")
        for t in terms:
            samples = per_term[t].get(b, [])
            if samples:
                v = mbps(samples)
                print(f"{v:>{col_w}.1f}", end="")
            else:
                print(f"{'-':>{col_w}}", end="")
        print()

    # Subset detection: per-bench MB/s varies ~10× within one terminal,
    # so a geomean over a SMALLER benchmark set (dropped 0-byte bench,
    # partial .dat, mid-suite crash) is not comparable to a full-set
    # geomean. Asterisk subset terminals and say what's missing.
    subset_terms: dict[str, list[str]] = {}
    for t in terms:
        missing = [b for b in benches if not per_term[t].get(b)]
        if missing:
            subset_terms[t] = missing

    # Aggregate: geometric mean of MB/s across benchmarks per terminal.
    print()
    print(f"{'geomean MB/s':<28}", end="")
    for t in terms:
        vals = []
        for b in benches:
            s = per_term[t].get(b, [])
            if s:
                v = mbps(s)
                if v == v and v != float("inf") and v > 0:
                    vals.append(v)
        if vals:
            gm = statistics.geometric_mean(vals)
            mark = "*" if t in subset_terms else ""
            print(f"{f'{gm:.1f}{mark}':>{col_w}}", end="")
        else:
            print(f"{'-':>{col_w}}", end="")
    print()

    # Ranking banner.
    ranks = []
    for t in terms:
        vals = [mbps(per_term[t].get(b, [])) for b in benches if per_term[t].get(b)]
        vals = [v for v in vals if v == v and v != float("inf") and v > 0]
        gm = statistics.geometric_mean(vals) if vals else 0.0
        ranks.append((t, gm))
    ranks.sort(key=lambda x: x[1], reverse=True)

    print()
    print("ranking (higher = faster):")
    for i, (t, gm) in enumerate(ranks, start=1):
        mark = "*" if t in subset_terms else ""
        print(f"  {i}. {t:<16} {gm:7.1f}{mark} MB/s")

    if subset_terms:
        print()
        print("  * geomean over a PARTIAL benchmark set — not comparable to")
        print("    full-set geomeans above; investigate before citing:")
        for t, missing in sorted(subset_terms.items()):
            print(f"    {t}: missing {', '.join(missing)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
