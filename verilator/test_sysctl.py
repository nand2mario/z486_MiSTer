#!/usr/bin/env python3
"""Boot the stock ao486 SYSCTL.EXE and verify its hardware control writes."""

from __future__ import annotations

import argparse
import re
import subprocess
import tempfile
from pathlib import Path


THIS_DIR = Path(__file__).resolve().parent
ROOT = THIS_DIR.parent.parent
DEFAULT_DISK = ROOT / "sdcard" / "doombench.img"
DEFAULT_SYSCTL = ROOT / "ao486_MiSTer" / "releases" / "drv" / "sysctl.exe"
EXPECTED = [0x80, 0x83, 0x82, 0x81, 0x00]


def run(*args: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=True, text=True, **kwargs)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sim", type=Path, default=THIS_DIR / "obj_dir" / "Vz486_mister_sim")
    parser.add_argument("--disk", type=Path, default=DEFAULT_DISK)
    parser.add_argument("--sysctl", type=Path, default=DEFAULT_SYSCTL)
    parser.add_argument("--end", type=int, default=250_000_000)
    args = parser.parse_args()

    for path in (args.sim, args.disk, args.sysctl):
        if not path.exists():
            parser.error(f"missing required file: {path}")

    autoexec = """@ECHO OFF\r
PATH C:\\DOS\r
C:\\SYSCTL.EXE SYS 90\r
C:\\SYSCTL.EXE SYS 56\r
C:\\SYSCTL.EXE SYS 30\r
C:\\SYSCTL.EXE SYS 15\r
C:\\SYSCTL.EXE MENU 90\r
ECHO SYSCTL_DONE\r
"""

    with tempfile.TemporaryDirectory(prefix="z486_sysctl_") as tmp:
        tmpdir = Path(tmp)
        disk = tmpdir / "sysctl.vhd"
        bat = tmpdir / "AUTOEXEC.BAT"
        run("cp", "--reflink=auto", "--sparse=always", str(args.disk), str(disk))
        bat.write_text(autoexec, encoding="ascii", newline="")
        run("mcopy", "-o", "-i", f"{disk}@@32256", str(args.sysctl), "::SYSCTL.EXE")
        run("mcopy", "-o", "-i", f"{disk}@@32256", str(bat), "::AUTOEXEC.BAT")

        proc = run(
            str(args.sim),
            "--disk", str(disk),
            "--headless",
            "--end", str(args.end),
            "--stop-on-text", "SYSCTL_DONE",
            cwd=THIS_DIR,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    observed = [int(value, 16) for value in re.findall(r"SYSCTL cfg=([0-9A-Fa-f]{2})", proc.stdout)]
    # Reset emits an initial zero; compare the final command sequence.
    if observed[-len(EXPECTED):] != EXPECTED:
        print(proc.stdout)
        print(f"FAIL: expected {[f'{v:02X}' for v in EXPECTED]}, got {[f'{v:02X}' for v in observed]}")
        return 1

    print("SYSCTL stock utility PASS: " + " -> ".join(f"{value:02X}" for value in EXPECTED))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
