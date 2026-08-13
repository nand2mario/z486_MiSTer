#!/usr/bin/env python3
"""Compare three independent five-seed Quartus experiments in parallel."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
import shlex
import statistics
import subprocess
import time

from seed_sweep import copy_project_for_seed


PROJECT_NAME = "22.z486_MiSTer"
SEEDS_PER_EXPERIMENT = 5
REMOTE_JOBS = 5
REMOTE_PROCESSORS_PER_JOB = 4
REMOTE_AFFINITY = {
    "venus_a": "0-19",
    "venus_b": "38-57",
}
REMOTE_MAX_CORES = 40
LOCAL_PROCESSORS_PER_JOB = 5


def parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start", type=int, default=1, help="first of five seeds used by every experiment")
    parser.add_argument("--oven-project", type=Path, default=here)
    parser.add_argument("--venus-a-project", type=Path, default=here)
    parser.add_argument("--venus-b-project", type=Path, default=here)
    parser.add_argument("--oven-label", default="oven")
    parser.add_argument("--venus-a-label", default="venus-a")
    parser.add_argument("--venus-b-label", default="venus-b")
    parser.add_argument("--remote", default="venus")
    parser.add_argument(
        "--remote-root",
        default="work/fpga/386-experiments/distributed_sweeps",
        help="path below the remote home directory",
    )
    parser.add_argument("--timing-paths", type=int, default=30)
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--no-rbf", action="store_true")
    return parser.parse_args()


def run_checked(cmd: list[str]) -> None:
    print("+", shlex.join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def ssh(host: str, command: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["ssh", host, command],
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def sweep_args(start: int, out: str, jobs: int, processors: int,
               timing_paths: int, no_rbf: bool) -> list[str]:
    args = [
        "python3", "seed_sweep.py",
        "--start", str(start),
        "--end", str(start + SEEDS_PER_EXPERIMENT - 1),
        "--jobs", str(jobs),
        "--processors-per-job", str(processors),
        "--timing-paths", str(timing_paths),
        "--out", out,
    ]
    if no_rbf:
        args.append("--no-rbf")
    return args


def launch_remote(host: str, root: str, lane: str, session: str,
                  start: int, timing_paths: int, no_rbf: bool) -> None:
    build_dir = f"$HOME/{root}/{lane}/{PROJECT_NAME}"
    exit_file = f"$HOME/{root}/{lane}.exit"
    sweep = sweep_args(
        start,
        "seed_sweep/distributed_results",
        REMOTE_JOBS,
        REMOTE_PROCESSORS_PER_JOB,
        timing_paths,
        no_rbf,
    )
    build_cmd = (
        "source \"$HOME/work/quartus/17.0/env.sh\"; "
        f"cd \"{build_dir}\"; "
        f"taskset -c {REMOTE_AFFINITY[lane]} {shlex.join(sweep)} > distributed_sweep.log 2>&1; "
        "rc=$?; "
        f"printf '%s\\n' \"$rc\" > \"{exit_file}\"; "
        "exit \"$rc\""
    )
    tmux_shell = shlex.join(["bash", "-lc", build_cmd])
    command = shlex.join(["tmux", "new-session", "-d", "-s", session, tmux_shell])
    result = ssh(host, command)
    if result.stdout:
        print(result.stdout, end="")


def remote_exit_codes(host: str, root: str, lanes: list[str]) -> dict[str, int]:
    tests = []
    for lane in lanes:
        path = f"$HOME/{root}/{lane}.exit"
        tests.append(f"if test -f \"{path}\"; then cat \"{path}\"; else echo running; fi")
    result = ssh(host, "; ".join(tests), check=False)
    codes: dict[str, int] = {}
    for lane, value in zip(lanes, result.stdout.splitlines(), strict=False):
        if value != "running":
            codes[lane] = int(value)
    return codes


def read_summary(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def write_comparison(out_dir: Path, lanes: list[tuple[str, str, Path]]) -> None:
    headers = [
        "lane", "version", "best WNS", "avg WNS", "median WNS",
        "avg TNS", "median TNS", "avg ALM", "max ALM",
    ]
    rows: list[list[str]] = []
    for lane, label, result_dir in lanes:
        values = read_summary(result_dir / "summary.csv")
        wns = [float(row["setup_slack"]) for row in values]
        tns = [float(row["setup_tns"]) for row in values]
        alms = [int(row["alms"]) for row in values]
        rows.append([
            lane,
            label,
            f"{max(wns):.3f}",
            f"{statistics.fmean(wns):.3f}",
            f"{statistics.median(wns):.3f}",
            f"{statistics.fmean(tns):.3f}",
            f"{statistics.median(tns):.3f}",
            f"{statistics.fmean(alms):.1f}",
            str(max(alms)),
        ])
    with (out_dir / "comparison.md").open("w") as f:
        f.write("| " + " | ".join(headers) + " |\n")
        f.write("| " + " | ".join(["---"] * len(headers)) + " |\n")
        for row in rows:
            f.write("| " + " | ".join(row) + " |\n")


def main() -> int:
    args = parse_args()
    if 2 * REMOTE_JOBS * REMOTE_PROCESSORS_PER_JOB > REMOTE_MAX_CORES:
        raise SystemExit("remote experiments exceed the 40-core limit")

    here = Path(__file__).resolve().parent
    stamp = time.strftime("%Y%m%d_%H%M%S")
    out_dir = (args.out or here / "seed_sweep" / f"experiments_{stamp}").resolve()
    out_dir.mkdir(parents=True, exist_ok=False)

    projects = {
        "oven": args.oven_project.resolve(),
        "venus_a": args.venus_a_project.resolve(),
        "venus_b": args.venus_b_project.resolve(),
    }
    labels = {
        "oven": args.oven_label,
        "venus_a": args.venus_a_label,
        "venus_b": args.venus_b_label,
    }
    snapshots: dict[str, Path] = {}
    for lane, project in projects.items():
        snapshot = out_dir / "src_snapshot" / lane / PROJECT_NAME
        copy_project_for_seed(project, snapshot)
        snapshots[lane] = snapshot

    remote_run = f"{args.remote_root}/{stamp}"
    remote_dirs = " ".join(
        f"\"$HOME/{remote_run}/{lane}/{PROJECT_NAME}\"" for lane in ("venus_a", "venus_b")
    )
    run_checked(["ssh", args.remote, f"mkdir -p {remote_dirs}"])
    for lane in ("venus_a", "venus_b"):
        # rsync's remote path is interpreted directly by the remote shell;
        # embedding a quoted $HOME here turns it into a literal directory.
        remote_project = f"{args.remote}:{remote_run}/{lane}/{PROJECT_NAME}/"
        run_checked(["rsync", "-az", "--delete", f"{snapshots[lane]}/", remote_project])
    ssh(args.remote, f"rm -f \"$HOME/{remote_run}/venus_a.exit\" \"$HOME/{remote_run}/venus_b.exit\"")

    session_prefix = f"z486_{stamp}"
    launch_remote(
        args.remote, remote_run, "venus_a", f"{session_prefix}_a",
        args.start, args.timing_paths, args.no_rbf,
    )
    launch_remote(
        args.remote, remote_run, "venus_b", f"{session_prefix}_b",
        args.start, args.timing_paths, args.no_rbf,
    )

    local_results = out_dir / "oven"
    local_cmd = sweep_args(
        args.start,
        str(local_results),
        SEEDS_PER_EXPERIMENT,
        LOCAL_PROCESSORS_PER_JOB,
        args.timing_paths,
        args.no_rbf,
    )
    local_log = (out_dir / "oven.log").open("w")
    print("+", shlex.join(local_cmd), flush=True)
    local_proc = subprocess.Popen(
        local_cmd,
        cwd=snapshots["oven"],
        stdout=local_log,
        stderr=subprocess.STDOUT,
    )

    remote_lanes = ["venus_a", "venus_b"]
    remote_codes: dict[str, int] = {}
    while local_proc.poll() is None or len(remote_codes) != len(remote_lanes):
        remote_codes = remote_exit_codes(args.remote, remote_run, remote_lanes)
        states = ", ".join(f"{lane}={remote_codes.get(lane, 'running')}" for lane in remote_lanes)
        local_state = local_proc.poll()
        print(
            f"[{time.strftime('%H:%M:%S')}] oven={local_state if local_state is not None else 'running'}, {states}",
            flush=True,
        )
        if local_proc.poll() is None or len(remote_codes) != len(remote_lanes):
            time.sleep(30)
    local_log.close()

    result_dirs: dict[str, Path] = {"oven": local_results}
    for lane in remote_lanes:
        local_lane = out_dir / lane
        local_lane.mkdir()
        remote_results = (
            f"{args.remote}:{remote_run}/{lane}/{PROJECT_NAME}/"
            "seed_sweep/distributed_results/"
        )
        run_checked(["rsync", "-az", remote_results, f"{local_lane}/"])
        result_dirs[lane] = local_lane

    if local_proc.returncode == 0 and all(code == 0 for code in remote_codes.values()):
        write_comparison(
            out_dir,
            [(lane, labels[lane], result_dirs[lane]) for lane in ("oven", "venus_a", "venus_b")],
        )
        print(f"Comparison: {out_dir / 'comparison.md'}")
        return 0

    print(f"experiment sweep failed: oven={local_proc.returncode}, remote={remote_codes}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
