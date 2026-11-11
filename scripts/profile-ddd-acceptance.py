#!/usr/bin/env python3
"""Profile one disposable NoteStore/SearchIndex workload with macOS sample."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import time
import os

MODES = {
    "discovery": "--profile-discovery",
    "save": "--profile-save",
    "search": "--profile-search",
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True, help="compiled current probe")
    parser.add_argument("--corpus", type=Path, required=True, help="generated fixture corpus")
    parser.add_argument("--work", type=Path, required=True, help="new disposable work directory")
    parser.add_argument("--mode", choices=MODES, required=True)
    parser.add_argument("--output", type=Path, required=True, help="sample output file")
    args = parser.parse_args()
    if args.work.exists() and any(args.work.iterdir()):
        parser.error("--work must be new or empty")
    args.work.mkdir(parents=True, exist_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    ready_file = args.work / "profile-ready"
    child_env = os.environ.copy()
    child_env["RAMNOTES_PROFILE_READY_FILE"] = str(ready_file)
    child = subprocess.Popen(
        [str(args.binary), str(args.corpus), str(args.work), "current", MODES[args.mode]],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=child_env,
    )
    deadline = time.monotonic() + 30
    while not ready_file.exists() and child.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    if not ready_file.exists():
        child.terminate()
        stdout, stderr = child.communicate()
        raise RuntimeError(f"probe did not become ready; exit={child.returncode}, stderr={stderr}")
    sample_seconds = "4" if args.mode == "discovery" else "8"
    result = subprocess.run(
        ["sample", str(child.pid), sample_seconds, "1", "-fullPaths", "-file", str(args.output)],
        capture_output=True, text=True,
    )
    try:
        stdout, stderr = child.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        child.terminate()
        stdout, stderr = child.communicate()
        raise RuntimeError("profile workload did not exit within 10 seconds")

    metadata = {
        "mode": args.mode,
        "child_pid": child.pid,
        "sample_seconds": int(sample_seconds),
        "profile_ready_marker": str(ready_file),
        "child_exit_code": child.returncode,
        "sample_exit_code": result.returncode,
        "sample_file": str(args.output),
        "workload_stdout": stdout.strip(),
        "workload_stderr": stderr.strip(),
        "sample_stdout": result.stdout.strip(),
        "sample_stderr": result.stderr.strip(),
    }
    metadata_path = args.output.with_suffix(args.output.suffix + ".json")
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    print(json.dumps(metadata, indent=2, sort_keys=True))
    if child.returncode != 0 or result.returncode != 0:
        raise SystemExit("profile failed; inspect metadata and sample output")


if __name__ == "__main__":
    main()
