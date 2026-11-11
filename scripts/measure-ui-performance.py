#!/usr/bin/env python3
"""Compile and optionally run unsigned window/editor component measurements."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import platform

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "scripts/performance-ui-probe.swift"
spec = importlib.util.spec_from_file_location("ddd_measure", ROOT / "scripts/measure-ddd-acceptance.py")
ddd_measure = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(ddd_measure)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="execute the timed component probe after compiling")
    parser.add_argument("--output", type=Path, help="new or empty artifact directory under /private/tmp")
    args = parser.parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix="ramnotes-ui-probe-", dir="/private/tmp"))
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    probe_copy = output / "performance-ui-probe.swift"
    shutil.copyfile(PROBE, probe_copy)
    source_hashes = ddd_measure.swift_source_hashes(ROOT)
    swift_version = subprocess.run(["xcrun", "swiftc", "--version"], text=True, capture_output=True, check=True).stdout.strip()
    uptime_before = subprocess.run(["uptime"], text=True, capture_output=True, check=True).stdout.strip()
    binary = ddd_measure.compile_variant(ROOT, output / "build", "current", probe_copy)
    print(json.dumps({"compiled": str(binary), "configuration": "swiftc -O -swift-version 6 -D APP_STORE; unsigned component probe", "timedRun": args.run}))
    if not args.run:
        return
    corpus = Path(tempfile.mkdtemp(prefix="ramnotes-benchmark-ui-", dir="/private/tmp"))
    try:
        subprocess.run(["python3", str(ROOT / "scripts/generate-fixtures.py"), "--output", str(corpus)],
                       cwd=ROOT, check=True)
        completed = subprocess.run([str(binary), str(corpus)], cwd=ROOT, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
        (output / "run.log").write_text(completed.stdout + completed.stderr)
        if completed.returncode:
            raise RuntimeError(f"UI probe failed; see {output / 'run.log'}")
        rows = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith("{")]
        if len(rows) != 6 or any(not row["countsValid"] for row in rows):
            raise RuntimeError(f"expected six rows with valid counts; got {len(rows)}")
        metadata = {
            "scope": "unsigned UI component, not signed Release or end-to-end input",
            "configuration": "swiftc -O -swift-version 6 -D APP_STORE",
            "architecture": platform.machine(),
            "swiftVersion": swift_version,
            "uptimeBefore": uptime_before,
            "probeSha256": hashlib.sha256(probe_copy.read_bytes()).hexdigest(),
            "ramnotesSwiftSources": source_hashes,
            "rows": rows,
        }
        (output / "results.json").write_text(json.dumps(metadata, indent=2) + "\n")
        print(json.dumps({"results": str(output / "results.json"), "rowCount": len(rows)}))
    finally:
        shutil.rmtree(corpus, ignore_errors=True)


if __name__ == "__main__":
    main()
