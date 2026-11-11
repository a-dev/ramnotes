#!/usr/bin/env python3
"""Generate disposable, deterministic notes for Phase 0 measurements."""

import argparse
from pathlib import Path
import os


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    safe_parent = Path("/private/tmp").resolve()
    if root.parent != safe_parent or not root.name.startswith("ramnotes-benchmark-"):
        parser.error("output must be a direct /tmp/ramnotes-benchmark-* directory")
    if root.exists() and any(root.iterdir()):
        parser.error("output must be new or empty")
    root.mkdir(parents=True, exist_ok=True)
    base_time = 1_700_000_000
    for index in range(1000):
        marker = f"marker-{index:04d}"
        prefix = f"Note {index:04d}\n{marker}\n"
        body = (prefix + (f"sample text {index:04d} " * 900))[:10_240]
        path = root / f"Note {index:04d}.txt"
        path.write_text(body, encoding="utf-8")
        os.utime(path, (base_time + index, base_time + index))
    stress = root / "Stress 1MB.txt"
    stress.write_text("Stress note\n" + "x" * (1_048_576 - 12), encoding="utf-8")
    os.utime(stress, (base_time + 1000, base_time + 1000))
    print(f"created 1000 notes and one 1 MB stress note in {root}")


if __name__ == "__main__":
    main()
