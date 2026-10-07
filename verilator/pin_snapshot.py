#!/usr/bin/env python3
"""Pin a portable snapshot as a named milestone, safe from --snapshot-keep.

The snapshot directory and the RAM keyframe it uses are hard-linked (same
file system) or copied into <root>/<name>/, laid out as a snapshot store
(<name>/snap_N plus <name>/keys/), so --restore-snapshot <root>/<name>/snap_N
works as before. A line goes to <root>/INDEX.md: name, sim time, source,
the git commit of the build in use, and the note.

usage: pin_snapshot.py <snapshot dir> <name> "<note>" [--root DIR] [--run "cmd hint"]
"""
import argparse
import os
import shutil
import subprocess
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("snapshot")
ap.add_argument("name")
ap.add_argument("note")
ap.add_argument("--root", default="cosim_snap/milestones")
ap.add_argument("--run", default="", help="what the restore needs (disk/floppy/cdrom, binary)")
a = ap.parse_args()

src = Path(a.snapshot).resolve()
meta = dict(line.split(" ", 1) for line in (src / "meta.txt").read_text().splitlines() if " " in line)
dst_root = Path(a.root)
dst = dst_root / a.name
if dst.exists():
    raise SystemExit(f"{dst} exists")
(dst / "keys").mkdir(parents=True)


def link_or_copy(s, d):
    try:
        os.link(s, d)
    except OSError:
        shutil.copy2(s, d)


(dst / src.name).mkdir()
for f in src.iterdir():
    link_or_copy(f, dst / src.name / f.name)
key = meta.get("ram_key", "").strip()
if key:
    link_or_copy(src.parent / "keys" / key, dst / "keys" / key)

commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True,
                        cwd=Path(__file__).parent).stdout.strip()
index = dst_root / "INDEX.md"
if not index.exists():
    index.write_text("# Pinned co-simulation snapshots\n\n"
                     "Restore: `--cosim --restore-snapshot <path>` with the same disk/floppy/cdrom "
                     "arguments (the images must be the files the run used).\n\n"
                     "| name | sim_time | snapshot | commit | note |\n|---|---|---|---|---|\n")
with index.open("a") as f:
    note = a.note + (f" Run: {a.run}" if a.run else "")
    f.write(f"| {a.name} | {meta.get('sim_time', '?').strip()} | {dst / src.name} | {commit} | {note} |\n")
print(f"pinned {src} -> {dst / src.name}")
