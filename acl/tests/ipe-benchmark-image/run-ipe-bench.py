#!/usr/bin/env python3
"""Run pinned upstream process and executable-mapping benchmarks."""

import json
import os
import platform
import random
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


STRESS_NG = "/usr/local/bin/stress-ng"
LAT_PROC = "/opt/lmbench/bin/lat_proc"
YAML_RATE = re.compile(
    r"^\s*bogo-ops-per-second-real-time:\s*([0-9.]+)\s*$", re.MULTILINE
)
LMBENCH_EXEC = re.compile(
    r"Process fork\+execve:\s*([0-9.]+)\s+microseconds", re.IGNORECASE
)


def positive_int(name, default):
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if value < 1:
        raise ValueError(f"{name} must be at least 1, got {value}")
    return value


def run(command, timeout):
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
    )
    if completed.returncode != 0:
        output = "\n".join(
            part.strip() for part in (completed.stdout, completed.stderr) if part.strip()
        )
        raise RuntimeError(
            f"command failed with exit code {completed.returncode}: "
            f"{' '.join(command)}\n{output}"
        )
    return "\n".join(
        part.strip() for part in (completed.stdout, completed.stderr) if part.strip()
    )


def tool_version(command):
    return run(command, timeout=30).strip()


def stress_sample(workload, operations, seed, timeout):
    with tempfile.NamedTemporaryFile(suffix=".yaml") as metrics:
        command = [
            STRESS_NG,
            "--seed",
            str(seed),
            f"--{workload}",
            "1",
            f"--{workload}-ops",
            str(operations),
            "--metrics",
            "--yaml",
            metrics.name,
        ]
        run(command, timeout=timeout)
        document = Path(metrics.name).read_text(encoding="utf-8")

    match = YAML_RATE.search(document)
    if not match or float(match.group(1)) <= 0:
        raise RuntimeError(
            f"stress-ng {workload} emitted no usable real-time operation rate"
        )
    return 1000.0 / float(match.group(1))


def lmbench_exec_sample(warmups, repetitions, timeout):
    output = run(
        [
            LAT_PROC,
            "-P",
            "1",
            "-W",
            str(warmups),
            "-N",
            str(repetitions),
            "exec",
        ],
        timeout=timeout,
    )
    match = LMBENCH_EXEC.search(output)
    if not match:
        raise RuntimeError(f"lat_proc emitted no exec latency:\n{output}")
    return float(match.group(1)) / 1000.0


def summarise(operation, tool, samples, **metadata):
    ordered = sorted(samples)
    row = {
        "suite": "ipe-container",
        "operation": operation,
        "tool": tool,
        "unit": "ms",
        "n": len(samples),
        "minMs": round(ordered[0], 6),
        "p50Ms": round(ordered[len(ordered) // 2], 6),
        "maxMs": round(ordered[-1], 6),
        "samplesMs": [round(sample, 6) for sample in samples],
    }
    row.update(metadata)
    return row


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def main():
    if os.geteuid() == 0:
        raise RuntimeError(
            "run-ipe-bench must run as non-root because upstream stress-ng "
            "disables its spawn stressor for effective UID 0"
        )

    repetitions = positive_int("IPE_BENCH_REPS", 7)
    warmup_repetitions = positive_int("IPE_BENCH_WARMUP_REPS", 1)
    fork_operations = positive_int("IPE_BENCH_FORK_OPS", 400)
    spawn_operations = positive_int("IPE_BENCH_SPAWN_OPS", 400)
    dynlib_operations = positive_int("IPE_BENCH_DYNLIB_OPS", 200)
    lmbench_warmups = positive_int("IPE_BENCH_LMBENCH_WARMUPS", 5)
    lmbench_repetitions = positive_int("IPE_BENCH_LMBENCH_REPETITIONS", 11)
    command_timeout = positive_int("IPE_BENCH_TIMEOUT_SECONDS", 900)
    seed = positive_int("IPE_BENCH_SEED", 20260806)
    output_path = Path(
        os.environ.get("IPE_BENCH_OUTPUT", "/tmp/ipe-bench-results.json")
    )

    workloads = {
        "stress-ng/fork": lambda sample_seed: stress_sample(
            "fork", fork_operations, sample_seed, command_timeout
        ),
        "stress-ng/spawn": lambda sample_seed: stress_sample(
            "spawn", spawn_operations, sample_seed, command_timeout
        ),
        "stress-ng/dynlib": lambda sample_seed: stress_sample(
            "dynlib", dynlib_operations, sample_seed, command_timeout
        ),
        "lmbench/lat_proc_exec": lambda _sample_seed: lmbench_exec_sample(
            lmbench_warmups, lmbench_repetitions, command_timeout
        ),
    }
    samples = {name: [] for name in workloads}

    print(
        f"Warming {len(workloads)} workloads "
        f"({warmup_repetitions} repetition(s) each)...",
        flush=True,
    )
    for warmup in range(warmup_repetitions):
        for index, workload in enumerate(workloads.values()):
            workload(seed + warmup * len(workloads) + index)

    started_at = utc_now()
    started_monotonic = time.monotonic()
    execution_order = []

    for repetition in range(repetitions):
        order = list(workloads)
        random.Random(seed + repetition).shuffle(order)
        execution_order.append(order)
        print(
            f"Recorded repetition {repetition + 1}/{repetitions}: "
            f"{', '.join(order)}",
            flush=True,
        )
        for index, name in enumerate(order):
            sample_seed = seed + 1000 + repetition * len(workloads) + index
            samples[name].append(workloads[name](sample_seed))

    metrics = [
        summarise(
            "fork",
            "stress-ng",
            samples["stress-ng/fork"],
            operationsPerRepetition=fork_operations,
        ),
        summarise(
            "spawn",
            "stress-ng",
            samples["stress-ng/spawn"],
            operationsPerRepetition=spawn_operations,
        ),
        summarise(
            "dynlib",
            "stress-ng",
            samples["stress-ng/dynlib"],
            operationsPerRepetition=dynlib_operations,
        ),
        summarise(
            "lat_proc_exec",
            "lmbench",
            samples["lmbench/lat_proc_exec"],
            lmbenchWarmups=lmbench_warmups,
            lmbenchRepetitions=lmbench_repetitions,
            nativeUnit="microseconds",
        ),
    ]

    document = {
        "schemaVersion": 1,
        "run": {
            "startedAt": started_at,
            "finishedAt": utc_now(),
            "durationSeconds": round(time.monotonic() - started_monotonic, 3),
            "repetitions": repetitions,
            "warmupRepetitions": warmup_repetitions,
            "seed": seed,
            "executionOrder": execution_order,
        },
        "environment": {
            "hostname": platform.node(),
            "kernel": platform.release(),
            "architecture": platform.machine(),
            "cpuCount": os.cpu_count(),
            "effectiveUid": os.geteuid(),
        },
        "tools": {
            "stressNg": tool_version([STRESS_NG, "--version"]),
            "lmbench": os.environ.get("LMBENCH_VERSION", "unknown"),
        },
        "metrics": metrics,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")

    print()
    print(f"{'operation':<20} {'n':>3} {'min ms':>12} {'p50 ms':>12} {'max ms':>12}")
    for row in metrics:
        print(
            f"{row['operation']:<20} {row['n']:>3} "
            f"{row['minMs']:>12.6f} {row['p50Ms']:>12.6f} "
            f"{row['maxMs']:>12.6f}"
        )
    print(f"\nResults written to {output_path}")
    print("IPE_BENCH_RESULTS=" + json.dumps(document, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"run-ipe-bench: {exc}", file=sys.stderr)
        sys.exit(1)
