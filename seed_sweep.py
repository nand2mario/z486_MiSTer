#!/usr/bin/env python3
"""Run a Quartus fitter seed sweep for the z486 MiSTer project.

Serial mode edits only sweep assignments in z486_mister.qsf, restores the
original file on exit, and archives reports for each seed. Parallel mode uses
isolated per-seed work trees under the sweep output directory, including local
copies of z486_MiSTer and z486.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


PROJECT = "z486_mister"
REVISION = "z486_mister"
MAIN_CLOCK_MARKER = "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk"
CLK_SYS_TOP_SETUP_RPT = f"{REVISION}.clk_sys_top_setup.rpt"
CLK_SYS_TOP_SETUP_TCL = f"{REVISION}.clk_sys_top_setup.tcl"
REQUIRED_BUILD_PROFILE = "production"


@dataclass
class Result:
    seed: int
    status: str
    elapsed_s: float
    fmax_mhz: str = ""
    setup_slack: str = ""
    setup_tns: str = ""
    hold_slack: str = ""
    hold_tns: str = ""
    alms: str = ""
    registers: str = ""
    ram_bits: str = ""
    ram_blocks: str = ""
    dsps: str = ""
    rbf: str = ""
    log: str = ""


def patch_seed(qsf: Path, seed: int) -> None:
    patch_global_assignment(qsf, "SEED", str(seed), "Fitter seed set by seed_sweep.py")


def patch_global_assignment(qsf: Path, name: str, value: str, comment: str | None = None) -> None:
    text = qsf.read_text()
    line = f"set_global_assignment -name {name} {value}"
    pattern = re.compile(rf"^set_global_assignment\s+-name\s+{re.escape(name)}\s+.*$", re.MULTILINE)
    if pattern.search(text):
        text = pattern.sub(line, text, count=1)
    else:
        if comment:
            text = text.rstrip() + f"\n\n# {comment}\n" + line + "\n"
        else:
            text = text.rstrip() + "\n" + line + "\n"
    qsf.write_text(text)


def active_build_profile(qsf: Path) -> str | None:
    match = re.search(r"^# Active profile:\s+(\w+)\s*$", qsf.read_text(), re.MULTILINE)
    return match.group(1) if match else None


def require_production_profile(qsf: Path) -> None:
    active = active_build_profile(qsf)
    if active != REQUIRED_BUILD_PROFILE:
        if active is None:
            state = "no active build_profile.py marker"
        else:
            state = f"active profile is {active!r}"
        raise SystemExit(
            "seed_sweep.py only runs with the production build profile; "
            f"{state}. Run ./build_profile.py production first."
        )


def resolve_processors_per_job(jobs: int, requested: int | None) -> int | None:
    if jobs < 1:
        raise SystemExit("--jobs must be >= 1")
    if requested is not None:
        if requested < 1:
            raise SystemExit("--processors-per-job must be >= 1")
        return requested
    if jobs <= 1:
        return None
    return max(1, (os.cpu_count() or jobs) // jobs)


def assert_signaltap_disabled(qsf: Path) -> None:
    active_bad: list[str] = []
    for line_no, raw in enumerate(qsf.read_text().splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if re.search(r"\bENABLE_SIGNALTAP\s+ON\b", line):
            active_bad.append(f"{line_no}: {raw}")
        if re.search(r"\b(USE_SIGNALTAP_FILE|SLD_FILE)\b", line):
            active_bad.append(f"{line_no}: {raw}")
    if active_bad:
        raise RuntimeError("SignalTap is still enabled or referenced:\n" + "\n".join(active_bad))


def event_stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def print_event(message: str, *, blank_before: bool = False) -> None:
    if blank_before:
        print()
    print(f"[{event_stamp()}] {message}", flush=True)


def run_cmd(cmd: list[str], cwd: Path, log: Path, stream: bool = True) -> int:
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    with log.open("w") as f:
        f.write("$ " + " ".join(cmd) + "\n")
        f.flush()
        proc = subprocess.Popen(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            if stream:
                sys.stdout.write(line)
            f.write(line)
        return proc.wait()


def write_clk_sys_top_setup_tcl(path: Path, npaths: int) -> None:
    """Write a TimeQuest script that reports top setup paths in the clk_sys domain."""
    path.write_text(
        "\n".join(
            [
                f"project_open {PROJECT} -revision {REVISION}",
                "create_timing_netlist",
                "read_sdc",
                "update_timing_netlist",
                f"set clk [get_clocks {{{MAIN_CLOCK_MARKER}}}]",
                (
                    "report_timing -setup "
                    f"-from_clock $clk -to_clock $clk -npaths {npaths} "
                    "-detail full_path "
                    f"-file output_files/{CLK_SYS_TOP_SETUP_RPT} "
                    "-panel_name {clk_sys Top Setup Paths}"
                ),
                "project_close",
                "",
            ]
        )
    )


def report_clk_sys_top_setup(project_dir: Path, seed_dir: Path, npaths: int, stream: bool = True) -> int:
    tcl = seed_dir / CLK_SYS_TOP_SETUP_TCL
    write_clk_sys_top_setup_tcl(tcl, npaths)
    return run_cmd(["quartus_sta", "-t", str(tcl)], project_dir, seed_dir / "clk_sys_top_setup.log", stream=stream)


def parse_timing_summary(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out

    current_type = ""
    current_clock = ""
    for raw in path.read_text(errors="ignore").splitlines():
        line = raw.strip()
        m = re.match(r"Type\s+:\s+(\S+)\s+'(.+)'", line)
        if m:
            current_type, current_clock = m.group(1), m.group(2)
            continue
        if current_clock != MAIN_CLOCK_MARKER:
            continue
        m = re.match(r"Slack\s+:\s+(-?\d+(?:\.\d+)?)", line)
        if m and current_type in {"Setup", "Hold"}:
            out[f"{current_type.lower()}_slack"] = m.group(1)
            continue
        m = re.match(r"TNS\s+:\s+(-?\d+(?:\.\d+)?)", line)
        if m and current_type in {"Setup", "Hold"}:
            out[f"{current_type.lower()}_tns"] = m.group(1)
            continue
    return out


def parse_fmax(path: Path) -> str:
    if not path.exists():
        return ""
    for raw in path.read_text(errors="ignore").splitlines():
        if MAIN_CLOCK_MARKER not in raw:
            continue
        cols = [c.strip() for c in raw.strip().strip(";").split(";")]
        if len(cols) >= 3 and "MHz" in cols[0]:
            return cols[0].replace(" MHz", "")
    return ""


def parse_fit_summary(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out

    for raw in path.read_text(errors="ignore").splitlines():
        if ":" not in raw:
            continue
        key, value = [x.strip() for x in raw.split(":", 1)]
        value = value.split("/")[0].strip()
        value = value.split("(")[0].strip()
        value = value.replace(",", "")
        if key == "Logic utilization (in ALMs)":
            out["alms"] = value
        elif key == "Total registers":
            out["registers"] = value
        elif key == "Total block memory bits":
            out["ram_bits"] = value
        elif key == "Total RAM Blocks":
            out["ram_blocks"] = value
        elif key == "Total DSP Blocks":
            out["dsps"] = value
    return out


def archive_outputs(project_dir: Path, seed_dir: Path, save_rbf: bool) -> str:
    output_dir = project_dir / "output_files"
    seed_dir.mkdir(parents=True, exist_ok=True)
    patterns = [
        f"{REVISION}.*.summary",
        f"{REVISION}.*.rpt",
        f"{REVISION}.sof",
        f"{REVISION}.smsg",
        f"{REVISION}.pin",
        f"{REVISION}.done",
    ]
    if save_rbf:
        patterns.append(f"{REVISION}.rbf")

    copied_rbf = ""
    for pattern in patterns:
        for src in output_dir.glob(pattern):
            dst = seed_dir / src.name
            shutil.copy2(src, dst)
            if src.suffix == ".rbf":
                copied_rbf = str(dst)
    return copied_rbf


def copy_tree(src: Path, dst: Path, ignored: set[str]) -> None:
    if dst.exists():
        shutil.rmtree(dst)

    def ignore(_dir: str, names: list[str]) -> set[str]:
        return {name for name in names if any(fnmatch.fnmatch(name, pattern) for pattern in ignored)}

    shutil.copytree(src, dst, ignore=ignore)


def copy_project_for_seed(project_dir: Path, dst: Path) -> None:
    ignored = {
        "__pycache__",
        "db",
        "incremental_db",
        "output_files",
        "seed_sweep",
        "greybox_tmp",
        "obj_dir",
        "tests",
        "verilator",
        "verilator_system",
        "*.log",
    }
    copy_tree(project_dir, dst, ignored)


def prepare_seed_work_tree(project_dir: Path, seed_dir: Path,
                           snapshot_dir: Path | None = None) -> Path:
    work_root = seed_dir / "work"
    if work_root.exists():
        shutil.rmtree(work_root)
    work_root.mkdir(parents=True)

    if snapshot_dir is not None:
        # Copy from the launch-time snapshot so source edits made while the
        # sweep runs cannot leak into later seed waves.
        shutil.copytree(snapshot_dir, work_root / project_dir.name)
    else:
        copy_project_for_seed(project_dir, work_root / project_dir.name)

    return work_root / project_dir.name


def run_one_seed(
    seed: int,
    project_dir: Path,
    out_dir: Path,
    no_clean: bool,
    save_rbf: bool,
    timing_paths: int,
    path_report: bool,
    processors_per_job: int | None,
    use_work_copy: bool,
    stream: bool,
    snapshot_dir: Path | None = None,
) -> Result:
    seed_dir = out_dir / f"seed_{seed:02d}"
    seed_dir.mkdir(parents=True, exist_ok=True)
    log = seed_dir / "quartus.log"

    build_dir = project_dir
    work_dir: Path | None = None
    if use_work_copy:
        work_dir = prepare_seed_work_tree(project_dir, seed_dir, snapshot_dir)
        build_dir = work_dir

    qsf = build_dir / f"{PROJECT}.qsf"
    patch_seed(qsf, seed)
    if processors_per_job is not None:
        patch_global_assignment(qsf, "NUM_PARALLEL_PROCESSORS", str(processors_per_job))
    assert_signaltap_disabled(qsf)

    start = time.monotonic()
    status = "ok"
    try:
        if not no_clean:
            clean_rc = run_cmd(
                ["quartus_sh", "--clean", "-c", REVISION, PROJECT],
                build_dir,
                seed_dir / "clean.log",
                stream=stream,
            )
            if clean_rc != 0:
                status = f"clean_failed:{clean_rc}"

        if status == "ok":
            compile_rc = run_cmd(
                ["quartus_sh", "--flow", "compile", PROJECT, "-c", REVISION],
                build_dir,
                log,
                stream=stream,
            )
            if compile_rc != 0:
                status = f"compile_failed:{compile_rc}"
            elif path_report:
                sta_rc = report_clk_sys_top_setup(build_dir, seed_dir, timing_paths, stream=stream)
                if sta_rc != 0:
                    status = f"path_report_failed:{sta_rc}"

        elapsed = time.monotonic() - start
        rbf = archive_outputs(build_dir, seed_dir, save_rbf)
        timing = parse_timing_summary(seed_dir / f"{REVISION}.sta.summary")
        fit = parse_fit_summary(seed_dir / f"{REVISION}.fit.summary")
        return Result(
            seed=seed,
            status=status,
            elapsed_s=round(elapsed, 1),
            fmax_mhz=parse_fmax(seed_dir / f"{REVISION}.sta.rpt"),
            setup_slack=timing.get("setup_slack", ""),
            setup_tns=timing.get("setup_tns", ""),
            hold_slack=timing.get("hold_slack", ""),
            hold_tns=timing.get("hold_tns", ""),
            alms=fit.get("alms", ""),
            registers=fit.get("registers", ""),
            ram_bits=fit.get("ram_bits", ""),
            ram_blocks=fit.get("ram_blocks", ""),
            dsps=fit.get("dsps", ""),
            rbf=rbf,
            log=str(log),
        )
    finally:
        if work_dir is not None:
            done_marker = seed_dir / "work_dir.txt"
            done_marker.write_text(str(work_dir) + "\n")


def write_csv(path: Path, results: list[Result]) -> None:
    fields = list(Result.__dataclass_fields__.keys())
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for result in results:
            writer.writerow(result.__dict__)


def write_markdown(path: Path, results: list[Result]) -> None:
    headers = [
        "seed",
        "status",
        "fmax_mhz",
        "setup_slack",
        "setup_tns",
        "hold_slack",
        "alms",
        "elapsed_s",
    ]
    with path.open("w") as f:
        f.write("| " + " | ".join(headers) + " |\n")
        f.write("| " + " | ".join(["---"] * len(headers)) + " |\n")
        for r in results:
            values = [str(getattr(r, h)) for h in headers]
            f.write("| " + " | ".join(values) + " |\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start", type=int, default=1, help="first seed, inclusive")
    parser.add_argument("--end", type=int, default=20, help="last seed, inclusive")
    parser.add_argument("--project-dir", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--out", type=Path, default=None, help="sweep output directory")
    parser.add_argument("--no-clean", action="store_true", help="do not run quartus_sh --clean before each seed")
    parser.add_argument("--no-rbf", action="store_true", help="do not archive per-seed .rbf files")
    parser.add_argument("--timing-paths", type=int, default=50, help="number of clk_sys setup paths to report after each successful build")
    parser.add_argument("--no-path-report", action="store_true", help="skip post-build clk_sys top setup path report")
    parser.add_argument("--stop-on-fail", action="store_true", help="stop after the first failed seed")
    parser.add_argument("--jobs", type=int, default=1, help="number of seeds to build in parallel")
    parser.add_argument(
        "--processors-per-job",
        type=int,
        default=None,
        help="override NUM_PARALLEL_PROCESSORS inside each build; default is floor(cpu_count / jobs) with --jobs > 1",
    )
    parser.add_argument(
        "--work-root",
        type=Path,
        default=None,
        help="deprecated; parallel work trees are stored under each seed output directory",
    )
    parser.add_argument("--keep-work", action="store_true", help="keep parallel worker project copies after the sweep")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    processors_per_job = resolve_processors_per_job(args.jobs, args.processors_per_job)
    project_dir = args.project_dir.resolve()
    qsf = project_dir / f"{PROJECT}.qsf"
    if not qsf.exists():
        raise SystemExit(f"missing QSF: {qsf}")
    require_production_profile(qsf)

    stamp = time.strftime("%Y%m%d_%H%M%S")
    out_dir = (args.out or (project_dir / "seed_sweep" / stamp)).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    original_qsf = qsf.read_text()
    backup_qsf = out_dir / f"{PROJECT}.qsf.before_sweep"
    backup_qsf.write_text(original_qsf)

    results: list[Result] = []
    seeds = list(range(args.start, args.end + 1))
    try:
        if args.jobs <= 1:
            for seed in seeds:
                print_event(f"=== seed {seed} ===", blank_before=True)
                result = run_one_seed(
                    seed=seed,
                    project_dir=project_dir,
                    out_dir=out_dir,
                    no_clean=args.no_clean,
                    save_rbf=not args.no_rbf,
                    timing_paths=args.timing_paths,
                    path_report=not args.no_path_report,
                    processors_per_job=processors_per_job,
                    use_work_copy=False,
                    stream=True,
                )
                results.append(result)
                write_csv(out_dir / "summary.csv", results)
                write_markdown(out_dir / "summary.md", results)
                print_event(
                    f"seed {seed}: {result.status}, fmax={result.fmax_mhz} MHz, "
                    f"WNS={result.setup_slack} ns, TNS={result.setup_tns} ns, "
                    f"hold={result.hold_slack} ns"
                )

                if result.status != "ok" and args.stop_on_fail:
                    break
        else:
            if args.work_root is not None:
                print_event("warning: --work-root is ignored; per-seed work trees live under the sweep output")

            # Snapshot the project (following the src/z486 symlink) ONCE at
            # launch: per-seed work trees copy from this, so the live tree
            # can keep moving while the sweep runs.
            snapshot_dir = out_dir / "src_snapshot" / project_dir.name
            copy_project_for_seed(project_dir, snapshot_dir)
            print_event(f"Source snapshot: {snapshot_dir}")
            print_event(
                f"Parallel sweep: jobs={args.jobs}, processors_per_job={processors_per_job}, "
                f"work_root={out_dir}/seed_XX/work"
            )
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
                pending: dict[concurrent.futures.Future[Result], int] = {}
                seed_iter = iter(seeds)
                stopping = False

                def submit_next() -> None:
                    try:
                        seed = next(seed_iter)
                    except StopIteration:
                        return
                    print_event(f"=== seed {seed} submitted ===")
                    fut = executor.submit(
                        run_one_seed,
                        seed,
                        project_dir,
                        out_dir,
                        args.no_clean,
                        not args.no_rbf,
                        args.timing_paths,
                        not args.no_path_report,
                        processors_per_job,
                        True,
                        False,
                        snapshot_dir,
                    )
                    pending[fut] = seed

                for _ in range(min(args.jobs, len(seeds))):
                    submit_next()

                while pending:
                    done, _ = concurrent.futures.wait(
                        pending, return_when=concurrent.futures.FIRST_COMPLETED
                    )
                    for fut in done:
                        seed = pending.pop(fut)
                        try:
                            result = fut.result()
                        except Exception as exc:  # noqa: BLE001 - keep sweep alive and record the failed seed
                            result = Result(
                                seed=seed,
                                status=f"script_failed:{type(exc).__name__}",
                                elapsed_s=0.0,
                                log=str(out_dir / f"seed_{seed:02d}" / "quartus.log"),
                            )
                            (out_dir / f"seed_{seed:02d}").mkdir(parents=True, exist_ok=True)
                            (out_dir / f"seed_{seed:02d}" / "script_error.txt").write_text(str(exc) + "\n")

                        results.append(result)
                        results.sort(key=lambda r: r.seed)
                        write_csv(out_dir / "summary.csv", results)
                        write_markdown(out_dir / "summary.md", results)
                        print_event(
                            f"seed {seed}: {result.status}, fmax={result.fmax_mhz} MHz, "
                            f"WNS={result.setup_slack} ns, TNS={result.setup_tns} ns, "
                            f"hold={result.hold_slack} ns"
                        )

                        if result.status != "ok" and args.stop_on_fail:
                            stopping = True

                        if not stopping:
                            submit_next()
    finally:
        qsf.write_text(original_qsf)
        if args.jobs > 1 and not args.keep_work:
            for seed in seeds:
                work_dir = out_dir / f"seed_{seed:02d}" / "work"
                if work_dir.exists():
                    shutil.rmtree(work_dir)
        print_event(f"Restored {qsf}", blank_before=True)
        print_event(f"Sweep output: {out_dir}")

    return 0 if all(r.status == "ok" for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
