"""Summarize Flutter lcov coverage per source folder (QA artifact)."""
import collections
import pathlib
import sys

path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1
                    else "flutter_app/coverage/lcov.info")
records = path.read_text(encoding="utf-8", errors="replace").split("end_of_record")
per_file = {}
for record in records:
    name = None
    lf = 0
    lh = 0
    for line in record.splitlines():
        if line.startswith("SF:"):
            name = line[3:].strip().replace("\\", "/")
        elif line.startswith("LF:"):
            lf = int(line[3:] or 0)
        elif line.startswith("LH:"):
            lh = int(line[3:] or 0)
    if name:
        per_file[name] = (lh, lf)

groups = collections.defaultdict(lambda: [0, 0])
for name, (lh, lf) in per_file.items():
    normalized = name.replace("\\", "/")
    if normalized.startswith("lib/"):
        rel = normalized[len("lib/"):]
    else:
        marker = "/lib/"
        idx = normalized.find(marker)
        rel = normalized[idx + len(marker):] if idx >= 0 else normalized
    group = rel.split("/")[0] if "/" in rel else "(root)"
    groups[group][0] += lh
    groups[group][1] += lf

total_h = sum(v[0] for v in per_file.values())
total_f = sum(v[1] for v in per_file.values())

print(f"files measured: {len(per_file)}")
print(f"{'folder':<12}{'lines hit':>10}{'lines found':>13}{'coverage':>10}")
for group in sorted(groups):
    hit, found = groups[group]
    pct = (100.0 * hit / found) if found else 0.0
    print(f"{group:<12}{hit:>10}{found:>13}{pct:>9.1f}%")
print(f"{'TOTAL':<12}{total_h:>10}{total_f:>13}"
      f"{(100.0 * total_h / total_f if total_f else 0):>9.1f}%")
print("\nlowest-covered files:")
for name, (hit, found) in sorted(per_file.items(),
                                 key=lambda kv: (kv[1][0] / kv[1][1]) if kv[1][1] else 1.0)[:8]:
    normalized = name.replace("\\", "/")
    if normalized.startswith("lib/"):
        rel = normalized[len("lib/"):]
    else:
        idx = normalized.find("/lib/")
        rel = normalized[idx + 5:] if idx >= 0 else normalized
    pct = (100.0 * hit / found) if found else 0.0
    print(f"  {rel:<48}{hit:>5}/{found:<5} {pct:>5.1f}%")
