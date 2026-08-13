#!/usr/bin/env python3
"""Switch z486 MiSTer Quartus build profiles.

The profile controls two things that are otherwise easy to mix up:

* the generated main PLL files under rtl/
* the top-level CLOCK_RATE_HZ localparam
* the timing/optimization assignments in z486_mister.qsf
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


PROJECT = "z486_mister"
PROJECT_DIR = Path(__file__).resolve().parent
QSF = PROJECT_DIR / "z486_mister.qsf"
TOP = PROJECT_DIR / "z486_mister.sv"
PROFILES_DIR = PROJECT_DIR / "profiles"

PLL_FILES = (
    Path("rtl/pll.qip"),
    Path("rtl/pll.v"),
    Path("rtl/pll/pll_0002.v"),
)

PROFILE_BLOCK_BEGIN = "# BEGIN build_profile.py settings"
PROFILE_BLOCK_END = "# END build_profile.py settings"


@dataclass(frozen=True)
class Profile:
    name: str
    description: str
    pll_summary: str
    clock_rate_hz: int
    assignments: tuple[tuple[str, str], ...]


PROFILES: dict[str, Profile] = {
    "base": Profile(
        name="base",
        description="50 MHz clk_sys, 225 degree SDRAM clock, conservative Quartus optimization",
        pll_summary="50 MHz, SDRAM phase 225 deg",
        clock_rate_hz=50_000_000,
        assignments=(
            ("OPTIMIZATION_MODE", "BALANCED"),
        ),
    ),
    "debug": Profile(
        name="debug",
        description="65 MHz clk_sys, 180 degree SDRAM clock, default-ish Quartus optimization",
        pll_summary="65 MHz, SDRAM phase 180 deg",
        clock_rate_hz=65_000_000,
        assignments=(
            ("OPTIMIZATION_MODE", "BALANCED"),
        ),
    ),
    "production": Profile(
        name="production",
        description="85 MHz clk_sys, 180 degree SDRAM clock, area-aware high-performance fit",
        pll_summary="85 MHz, SDRAM phase 180 deg",
        clock_rate_hz=85_000_000,
        assignments=(
            ("OPTIMIZE_POWER_DURING_FITTING", "OFF"),
            ("FINAL_PLACEMENT_OPTIMIZATION", "ALWAYS"),
            ("FITTER_EFFORT", '"STANDARD FIT"'),
            ("OPTIMIZATION_MODE", '"HIGH PERFORMANCE EFFORT"'),
            ("ALLOW_POWER_UP_DONT_CARE", "ON"),
            ("QII_AUTO_PACKED_REGISTERS", '"SPARSE AUTO"'),
            ("ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION", "ON"),
            ("PHYSICAL_SYNTHESIS_COMBO_LOGIC", "ON"),
            ("PHYSICAL_SYNTHESIS_EFFORT", "EXTRA"),
            ("PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION", "ON"),
            ("PHYSICAL_SYNTHESIS_REGISTER_RETIMING", "ON"),
            ("OPTIMIZATION_TECHNIQUE", "SPEED"),
            ("MUX_RESTRUCTURE", "ON"),
            ("REMOVE_REDUNDANT_LOGIC_CELLS", "ON"),
            ("AUTO_DELAY_CHAINS_FOR_HIGH_FANOUT_INPUT_PINS", "ON"),
            ("PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA", "ON"),
            ("ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP", "ON"),
            ("SYNTH_GATED_CLOCK_CONVERSION", "ON"),
            ("PRE_MAPPING_RESYNTHESIS", "ON"),
            ("ROUTER_CLOCKING_TOPOLOGY_ANALYSIS", "ON"),
            ("ECO_OPTIMIZE_TIMING", "ON"),
            ("PERIPHERY_TO_CORE_PLACEMENT_AND_ROUTING_OPTIMIZATION", "ON"),
            ("PHYSICAL_SYNTHESIS_ASYNCHRONOUS_SIGNAL_PIPELINING", "ON"),
            ("ALM_REGISTER_PACKING_EFFORT", "LOW"),
            ("OPTIMIZE_POWER_DURING_SYNTHESIS", "OFF"),
            ("ROUTER_REGISTER_DUPLICATION", "ON"),
            ("FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION", "ALWAYS"),
            ("SEED", "6"),
        ),
    ),
}

CONTROLLED_ASSIGNMENTS = frozenset(
    name for profile in PROFILES.values() for name, _ in profile.assignments
)


def qsf_assignment_line(name: str, value: str) -> str:
    return f"set_global_assignment -name {name} {value}"


def remove_managed_qsf_content(text: str) -> str:
    block_re = re.compile(
        rf"\n?{re.escape(PROFILE_BLOCK_BEGIN)}.*?{re.escape(PROFILE_BLOCK_END)}\n?",
        re.DOTALL,
    )
    text = block_re.sub("\n", text)

    filtered: list[str] = []
    assignment_re = re.compile(r"^\s*set_global_assignment\s+-name\s+([A-Z0-9_]+)\b")
    for line in text.splitlines():
        match = assignment_re.match(line)
        if match and match.group(1) in CONTROLLED_ASSIGNMENTS:
            continue
        filtered.append(line)
    return "\n".join(filtered).rstrip() + "\n"


def insert_profile_qsf_block(text: str, profile: Profile) -> str:
    block = [
        PROFILE_BLOCK_BEGIN,
        f"# Active profile: {profile.name}",
        f"# {profile.description}",
    ]
    block.extend(qsf_assignment_line(name, value) for name, value in profile.assignments)
    block.append(PROFILE_BLOCK_END)
    block_text = "\n".join(block)

    marker = 'set_global_assignment -name TIMEQUEST_MULTICORNER_ANALYSIS OFF'
    if marker in text:
        return text.replace(marker, marker + "\n" + block_text, 1)

    return text.rstrip() + "\n\n" + block_text + "\n"


def apply_qsf_profile(profile: Profile, dry_run: bool) -> None:
    text = QSF.read_text()
    updated = insert_profile_qsf_block(remove_managed_qsf_content(text), profile)
    if dry_run:
        if updated != text:
            print(f"Would update {QSF.relative_to(PROJECT_DIR)}")
        return
    QSF.write_text(updated)


def copy_pll_profile(profile: Profile, dry_run: bool) -> None:
    profile_dir = PROFILES_DIR / profile.name
    missing = [str(profile_dir / path) for path in PLL_FILES if not (profile_dir / path).exists()]
    if missing:
        raise SystemExit("Missing profile PLL files:\n" + "\n".join(missing))

    for rel in PLL_FILES:
        src = profile_dir / rel
        dst = PROJECT_DIR / rel
        if dry_run:
            print(f"Would copy {src.relative_to(PROJECT_DIR)} -> {dst.relative_to(PROJECT_DIR)}")
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def format_clock_rate(value: int) -> str:
    return f"{value:_}"


def apply_top_clock_rate(profile: Profile, dry_run: bool) -> None:
    text = TOP.read_text()
    updated, count = re.subn(
        r"^localparam[ \t]+CLOCK_RATE_HZ[ \t]*=[ \t]*[0-9_]+;[ \t]*$",
        f"localparam CLOCK_RATE_HZ = {format_clock_rate(profile.clock_rate_hz)};",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise SystemExit(f"Expected exactly one CLOCK_RATE_HZ localparam in {TOP.name}")

    if dry_run:
        if updated != text:
            print(f"Would update {TOP.relative_to(PROJECT_DIR)}")
        return
    TOP.write_text(updated)


def apply_profile(profile: Profile, dry_run: bool) -> None:
    copy_pll_profile(profile, dry_run)
    apply_top_clock_rate(profile, dry_run)
    apply_qsf_profile(profile, dry_run)
    if dry_run:
        return
    print(f"Applied {profile.name}: {profile.pll_summary}")


def detect_active_profile() -> str | None:
    qsf_text = QSF.read_text()
    match = re.search(r"# Active profile: (\w+)", qsf_text)
    if not match:
        return None
    name = match.group(1)
    return name if name in PROFILES else None


def run_quartus() -> int:
    return subprocess.call(["quartus_sh", "--flow", "compile", PROJECT], cwd=PROJECT_DIR)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", nargs="?", choices=sorted(PROFILES), help="profile to apply")
    parser.add_argument("--list", action="store_true", help="list available profiles")
    parser.add_argument("--show", action="store_true", help="show the currently recorded active profile")
    parser.add_argument("--dry-run", action="store_true", help="print changes without writing files")
    parser.add_argument("--compile", action="store_true", help="run quartus_sh after applying the profile")
    args = parser.parse_args(argv)

    if args.list:
        for profile in PROFILES.values():
            print(f"{profile.name:10} {profile.description}")
        return 0

    if args.show:
        active = detect_active_profile()
        if active is None:
            print("No active build_profile.py profile marker in z486_mister.qsf")
        else:
            print(f"Active profile marker: {active} ({PROFILES[active].pll_summary})")
        return 0

    if args.profile is None:
        parser.error("choose a profile, or use --list/--show")

    profile = PROFILES[args.profile]
    apply_profile(profile, args.dry_run)

    if args.compile and not args.dry_run:
        return run_quartus()

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
