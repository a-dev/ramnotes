#!/usr/bin/env python3
"""Measure process-kill exposure for the disposable StorageProbe journal loop."""

import json
import re
import subprocess
import tempfile
import time
from pathlib import Path


PROBE = Path("/private/tmp/ramnotes-storage-probe")
DELAYS = (0.31, 0.43, 0.55, 0.67, 0.79)


def run(*args: str, expected: int = 0) -> str:
    result = subprocess.run((str(PROBE), *args), capture_output=True, text=True)
    if result.returncode != expected:
        raise RuntimeError(f"{args}: exit={result.returncode}; stderr={result.stderr}")
    return result.stdout.strip()


def crash_window() -> None:
    print("kill_delay_ms last_edit journaled lost_edits measured_exposure_ms")
    for delay in DELAYS:
        with tempfile.TemporaryDirectory(prefix="ramnotes-storage-probe-crash-", dir="/private/tmp") as directory:
            run("setup", directory)
            process = subprocess.Popen(
                (str(PROBE), "journal-loop", directory),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            assert process.stdout is not None
            first_line = process.stdout.readline()
            if not first_line.startswith("edit=1 "):
                remaining, errors = process.communicate()
                raise RuntimeError(f"journal loop did not start: {first_line!r} {remaining!r} {errors!r}")
            time.sleep(delay)
            process.kill()
            remaining, errors = process.communicate()
            if errors:
                raise RuntimeError(errors)
            lines = (first_line + remaining).splitlines()
            edits = [tuple(map(int, match.groups())) for line in lines if (match := re.fullmatch(r"edit=(\d+) elapsedMs=(\d+)", line))]
            journal_events = [tuple(map(int, match.groups())) for line in lines if (match := re.fullmatch(r"journal=(\d+) elapsedMs=(\d+)", line))]
            if not edits or not journal_events:
                raise RuntimeError(f"missing events at {delay}s: {lines!r}")
            journal = json.loads((Path(directory) / "journal.json").read_text())
            journaled = journal["revision"]
            journal_time = max(ms for rev, ms in journal_events if rev == journaled)
            last_edit, edit_time = edits[-1]
            print(f"{round(delay * 1000):>13} {last_edit:>9} {journaled:>9} {last_edit - journaled:>10} {edit_time - journal_time:>20}")
            recovered = run("recover", directory)
            if recovered != "saved-now":
                raise RuntimeError(f"recovery failed: {recovered}")
            disk = (Path(directory) / "Note.txt").read_text()
            if disk != f"edit {journaled}\n":
                raise RuntimeError(f"unexpected recovered text: {disk!r}")


def promotion_crash() -> None:
    with tempfile.TemporaryDirectory(prefix="ramnotes-storage-probe-promotion-", dir="/private/tmp") as directory:
        run("setup", directory)
        run("journal", directory)
        run("external-edit", directory)
        result = run("promotion-crash", directory, expected=99)
        recovered = run("recover", directory)
        files = list(Path(directory).glob("Recovery *.txt"))
        if result != "recovery-written-before-journal-cleanup" or recovered != "conflict-recovered" or len(files) != 1:
            raise RuntimeError(f"promotion recovery failed: {result}, {recovered}, {files}")
        if (Path(directory) / "Note.txt").read_text() != "external edit\n":
            raise RuntimeError("external version was lost")
        print("promotion_crash recovered_once=true external_version_preserved=true")


if __name__ == "__main__":
    crash_window()
    promotion_crash()
