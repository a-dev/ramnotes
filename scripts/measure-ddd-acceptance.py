#!/usr/bin/env python3
"""Compare two revisions of NoteStore discovery, save, and search paths."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import shutil
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parent.parent
BASELINE = "1701cde"
TARGET = "arm64-apple-macos27.0"
PROBE = REPO / "scripts/ddd-acceptance-probe.swift"


def run(command: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
        stdout=None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        command, cwd=cwd, env=env,
        stdout=stdout if stdout is not None else subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, check=check,
    )


def archive(ref: str, destination: Path) -> str:
    resolved = run(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=REPO).stdout.strip()
    destination.mkdir(parents=True, exist_ok=True)
    archive_path = destination.with_suffix(".tar")
    with archive_path.open("wb") as stream:
        run(["git", "archive", resolved], cwd=REPO, stdout=stream)
    with tarfile.open(archive_path) as source:
        source.extractall(destination, filter="data")
    return resolved


def swift_source_hashes(root: Path) -> list[dict[str, str]]:
    return [
        {"path": source.relative_to(root).as_posix(),
         "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
        for source in sorted((root / "ramnotes").rglob("*.swift"))
    ]


def overlay_worktree_sources(destination: Path) -> tuple[list[dict[str, str]], str]:
    source_root = REPO / "ramnotes"
    destination_root = destination / "ramnotes"
    current_sources = {
        source.relative_to(source_root).as_posix(): source
        for source in source_root.rglob("*.swift")
    }
    archived_sources = {
        source.relative_to(destination_root).as_posix(): source
        for source in destination_root.rglob("*.swift")
    }
    for relative, source in archived_sources.items():
        if relative not in current_sources:
            source.unlink()
    for relative, source in current_sources.items():
        target = destination_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)

    diff = run(["git", "diff", "HEAD", "--binary", "--", ":(glob)ramnotes/**/*.swift"], cwd=REPO).stdout.encode()
    digest = hashlib.sha256()
    digest.update(diff)
    untracked = run(["git", "ls-files", "--others", "--exclude-standard", "--", "ramnotes"], cwd=REPO).stdout.splitlines()
    for relative in sorted(path for path in untracked if path.endswith(".swift")):
        digest.update(relative.encode())
        digest.update(b"\0")
        digest.update((REPO / relative).read_bytes())
        digest.update(b"\0")
    return swift_source_hashes(destination), digest.hexdigest()


def compile_variant(root: Path, output: Path, variant: str, probe: Path) -> Path:
    output.mkdir(parents=True, exist_ok=True)
    domain = output / "domain"
    sources = sorted((root / "ramnotes").rglob("*.swift"))
    modular_domain = any("import ramnotesDomain" in source.read_text() for source in sources)
    if modular_domain:
        domain.mkdir()
        cmd = ["xcrun", "swiftc", "-O", "-swift-version", "6", "-target", TARGET,
               "-module-cache-path", str(output / "DomainModuleCache"), "-emit-library", "-static", "-emit-module",
               "-module-name", "ramnotesDomain", "-emit-module-path", str(domain / "ramnotesDomain.swiftmodule"),
               str(root / "ramnotes/Domain/NoteValues.swift"), "-o", str(domain / "libramnotesDomain.a")]
        result = run(cmd, cwd=root, check=False)
        (output / "domain-build.log").write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"domain module build failed; see {output / 'domain-build.log'}")

    paths: list[str] = []
    generated = output / "sources"
    generated.mkdir()
    for source in sources:
        relative = source.relative_to(root / "ramnotes")
        if modular_domain and relative.as_posix() == "Domain/NoteValues.swift":
            continue
        text = source.read_text()
        if relative.as_posix() == "App/main.swift":
            startup = "let application = NSApplication.shared"
            if startup in text:
                text = text[:text.index(startup)]
        destination = generated / relative.as_posix().replace("/", "_")
        destination.write_text(text)
        paths.append(str(destination))

    cmd = ["xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library", "-D", "APP_STORE", "-target", TARGET,
           "-module-cache-path", str(output / "ModuleCache")]
    if modular_domain:
        cmd += ["-I", str(domain), "-L", str(domain), "-lramnotesDomain"]
    cmd += paths + [str(probe), "-o", str(output / "probe")]
    result = run(cmd, cwd=root, check=False)
    (output / "probe-build.log").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f"{variant} probe build failed; see {output / 'probe-build.log'}")
    return output / "probe"


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def summarize(values: list[float]) -> dict[str, float]:
    return {"median": statistics.median(values), "min": min(values), "max": max(values)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5, help="fresh-process runs per variant; minimum 5")
    parser.add_argument("--current", default="HEAD", help="commit/ref to archive, or WORKTREE for the current ramnotes Swift sources (default: HEAD)")
    parser.add_argument("--baseline", default=BASELINE, help="comparison commit/ref (default: pre-DDD 1701cde)")
    parser.add_argument("--output", type=Path, help="artifact directory; default under /private/tmp")
    args = parser.parse_args()
    if args.runs < 5:
        parser.error("--runs must be at least 5")
    if not Path("/private/tmp").exists():
        parser.error("this macOS benchmark requires /private/tmp")

    artifacts = Path("/private/tmp/ramnotes-step6-perf")
    artifacts.mkdir(parents=True, exist_ok=True)
    output = args.output or Path(tempfile.mkdtemp(prefix="run-", dir=artifacts))
    if output.exists() and any(output.iterdir()):
        parser.error("--output must be new or empty")
    output.mkdir(parents=True, exist_ok=True)
    probe_snapshot = output / "Probe.swift"
    shutil.copyfile(PROBE, probe_snapshot)
    probe_hash = hashlib.sha256(probe_snapshot.read_bytes()).hexdigest()
    baseline_root, current_root = output / "baseline", output / "current"
    baseline_hash = archive(args.baseline, baseline_root)
    worktree_current = args.current.upper() == "WORKTREE"
    current_ref = "HEAD" if worktree_current else args.current
    current_hash = archive(current_ref, current_root)
    if worktree_current:
        current_sources, dirty_diff_hash = overlay_worktree_sources(current_root)
    else:
        current_sources, dirty_diff_hash = swift_source_hashes(current_root), None
    source_manifest_path = output / "source-manifest.json"
    source_manifest = {
        "baseline_commit": baseline_hash,
        "current_commit": current_hash,
        "current_mode": "WORKTREE" if worktree_current else "commit/ref",
        "ramnotes_swift_dirty_diff_sha256": dirty_diff_hash,
        "baseline_sources": swift_source_hashes(baseline_root),
        "current_sources": current_sources,
    }
    source_manifest_path.write_text(json.dumps(source_manifest, indent=2, sort_keys=True) + "\n")
    source_manifest_hash = hashlib.sha256(source_manifest_path.read_bytes()).hexdigest()
    corpus = Path(tempfile.mkdtemp(prefix="ramnotes-benchmark-", dir="/private/tmp"))
    run(["python3", str(REPO / "scripts/generate-fixtures.py"), "--output", str(corpus)], cwd=REPO)
    binaries = {
        "baseline": compile_variant(baseline_root, output / "bin/baseline", "baseline", probe_snapshot),
        "current": compile_variant(current_root, output / "bin/current", "current", probe_snapshot),
    }

    def command_output(command: list[str]) -> str:
        result = run(command, check=False)
        return (result.stdout + result.stderr).strip()

    environment = {
        "os": command_output(["sw_vers"]),
        "architecture": platform.machine(),
        "processor_count": command_output(["getconf", "_NPROCESSORS_ONLN"]),
        "uptime_before": command_output(["uptime"]),
        "swift_version": command_output(["xcrun", "swiftc", "--version"]),
        "configuration": "swiftc -O -swift-version 6 -D APP_STORE; updater excluded; unsigned component harness and static domain module, not the signed Release app",
        "cache_state": "the fixture is copied immediately before discovery, so file-system page cache may be warm; this is not cold-I/O budget proof",
        "scope": "default-folder NoteStore discovery/save and SearchIndex only; excludes app launch, activation, editor rendering, and end-to-end typing latency",
        "baseline_commit": baseline_hash,
        "current_commit": current_hash,
        "current_mode": "WORKTREE" if worktree_current else "commit/ref",
        "ramnotes_swift_dirty_diff_sha256": dirty_diff_hash,
        "source_manifest_sha256": source_manifest_hash,
        "source_manifest_path": str(source_manifest_path),
        "corpus_path": str(corpus),
        "corpus_files": 1001,
        "corpus_note_bytes": 10_240,
        "corpus_stress_bytes": 1_048_576,
        "expected_materialized_utf8_bytes": 11_288_576,
        "probe_sha256": probe_hash,
        "alternation": "baseline, current, repeated",
    }
    results: dict[str, list[dict]] = {"baseline": [], "current": []}
    for index in range(args.runs):
        for variant in ("baseline", "current"):
            work = output / "runs" / f"{index + 1:02d}-{variant}"
            command_env = os.environ.copy()
            result = run([str(binaries[variant]), str(corpus), str(work), variant], env=command_env,
                         check=False)
            if result.returncode:
                (output / "failed-run.log").write_text(result.stdout + result.stderr)
                raise RuntimeError(f"{variant} run {index + 1} failed; see {output / 'failed-run.log'}")
            lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
            if len(lines) != 1:
                raise RuntimeError(f"expected one JSON report from {variant} run {index + 1}")
            row = json.loads(lines[0])
            valid_work = (
                row["discovered"] == 1001 and row["unavailable"] == 0
                and row["discoveredUTF8Bytes"] == 11_288_576
                and row["savesSucceeded"] == 30 and row["savedBytesVerified"]
                and row["eachSaveChangedExpectedContent"] and len(row["searchMilliseconds"]) == 30
            )
            if not valid_work:
                raise RuntimeError(f"incorrect work counts in {variant} run {index + 1}: {row}")
            results[variant].append(row)
            print(f"{index + 1}/{args.runs} {variant}: discover={row['discoveryMilliseconds']:.2f}ms, "
                  f"save-p50={statistics.median(row['saveMilliseconds']):.2f}ms, "
                  f"search-p95={percentile(row['searchMilliseconds'], .95):.2f}ms", flush=True)

    metrics = {}
    for variant, rows in results.items():
        discovery = [row["discoveryMilliseconds"] for row in rows]
        save_run_medians = [statistics.median(row["saveMilliseconds"]) for row in rows]
        search_run_p95 = [percentile(row["searchMilliseconds"], .95) for row in rows]
        metrics[variant] = {
            "discovery_ms_per_fresh_process": summarize(discovery),
            "save_ms_median_per_run": summarize(save_run_medians),
            "search_ms_p95_per_run": summarize(search_run_p95),
            "successful_saves": sum(row["savesSucceeded"] for row in rows),
            "search_results_validated": sum(len(row["searchCounts"]) for row in rows),
            "wrong_results": 0,
        }
    report = {"environment": environment, "runs_per_variant": args.runs, "metrics": metrics,
              "limiter": "not independently profiled; keep any speedup/regression verdict inconclusive until a separate profile identifies the bottleneck",
              "budgets": {"cold_scan_ms": 1000, "search_query_p95_ms": 100},
              "raw": results}
    path = output / "results.json"
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"artifact": str(path), "metrics": metrics}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
