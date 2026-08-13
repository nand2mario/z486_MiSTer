#!/usr/bin/env bash
# Select the z486 CPU source tree by repointing the src/z486 symlink.
# Everything (QSF, files.qip, Verilator simulation) resolves the core through
# this path, so it remains the single switch point.
#
#   ./set_core.sh        show the current selection
#   ./set_core.sh 24     use 24.z486
#   ./set_core.sh 486    same as above
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

case "${1:-}" in
    "")
        echo "src/z486 -> $(readlink src/z486)"
        exit 0
        ;;
    24|486) target=../../24.z486 ;;
    *)
        echo "usage: $0 [24|486]" >&2
        exit 1
        ;;
esac

ln -sfn "$target" src/z486
echo "src/z486 -> $target"
