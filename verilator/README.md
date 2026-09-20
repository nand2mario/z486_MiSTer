# z486 MiSTer Verilator harness

## Build

The default simulator includes the x87 unit, matching the MiSTer build:

```sh
make
```

Use the explicit reduced target only when testing behavior without an FPU:

```sh
make no_x87
```

The binaries are `obj_dir/Vz486_mister_sim` and
`obj_dir_no_x87/Vz486_mister_sim`, respectively.

## Disk images

Use `--disk` for the IDE0 hard-disk image and `--cdrom` for an IDE1 ISO image:

```sh
./obj_dir/Vz486_mister_sim \
  --disk /tmp/dos.vhd \
  --cdrom /tmp/game.iso
```

The CD-ROM model implements the ATAPI packet commands used by DOS CD drivers.
Audio-track playback is accepted for software compatibility but is not rendered
by the simulator.

## SVGA framebuffer formats

The simulator defaults to the MiSTer core's BGR/1555 framebuffer settings.
Use `--fb-rgb` or `--fb-565` to test software that expects the alternate channel
order or 16-bit format; `--fb-bgr` and `--fb-1555` restore the defaults.

## DDR3 waitrequest injection

`DDRAM_BUSY` is the HPS f2sdram bridge's Avalon-MM `waitrequest`; on hardware it
rises for DDR3 refresh and for other bridge masters, but the simulator normally
keeps it low. Two options inject it so that masters that must hold a request
until it is accepted can be exercised:

```sh
./obj_dir/Vz486_mister_sim --headless --end 8000000 --ddr-busy 7,3
./obj_dir/Vz486_mister_sim --headless --end 8000000 --ddr-busy-rand 30[,SEED]
```

`--ddr-busy P[,L]` asserts busy for `L` cycles (default 1) out of every `P`;
`--ddr-busy-rand N[,SEED]` asserts it on a pseudo-random `N`% of cycles. Prefer the
random mode: a request FSM with a fixed loop length synchronises to a periodic
pattern and then never issues into a busy cycle. The DDR model samples `rd`,
`we`, `busy` and the address/data at the rising edge as a real slave does, and
reports `DDR: dropped read request` if a read presented into a busy cycle is
deasserted before it is accepted. Injection state is not saved in checkpoints.

## PC+zSST simulation

Clone [zSST](https://github.com/nand2mario/zSST) beside this repository, then
build the opt-in whole-PC Voodoo configuration with:

```sh
ZSST=../../zSST
make voodoo ZSST="$ZSST"
```

`--zsst-debug` prints PCI, initialization, rendering, and video events.
`--zsst-write-trace <path>` records accepted SST-1 writes for fast replay in
zSST's replay tools, and periodic screenshots capture the active zSST framebuffer once
Glide has enabled video. If a DOS batch file prints
`VOODOO_TESTnn_START`/`VOODOO_TESTnn_DONE`, those boundaries are recorded as
trace comments so a multi-test boot can be split into independent replays:

```sh
./obj_dir_voodoo/Vz486_mister_sim \
  --disk /tmp/glide-tests.vhd \
  --zsst-write-trace /tmp/test00.ops \
  --screenshot-dir /tmp/test00-shots \
  --screenshot-interval 1000000

python3 "$ZSST"/tools/trace/split_glide_trace.py \
  /tmp/glide-suite.ops /tmp/glide-tests
```

## Legacy VGA plane capture

Legacy 256-color VGA modes use four local plane RAMs rather than the SVGA DDR
framebuffer. Capture and independently decode those planes at a simulator time
with:

```sh
./obj_dir/Vz486_mister_sim --disk /tmp/game.vhd \
  --vga-plane-at 170000000:/tmp/vga.png
```

This writes the decoded PNG and a sibling `vga.vga.bin` containing the mode
metadata, four 64 KiB planes, and 256 18-bit DAC entries. The PNG bypasses VGA
timing and scanout, which makes it a useful reference when diagnosing display
pipeline errors.

## Live control socket

Start the simulator with a localhost TCP control socket:

```sh
./obj_dir/Vz486_mister_sim --disk ../../sdcard/win311_auto.vhd --control-port 9386
```

Send a single command with `simctl.py`:

```sh
./simctl.py status
./simctl.py mouse -20 -40 0
./simctl.py key enter
./simctl.py screenshot /tmp/z386.png
./simctl.py checkpoint
```

With no command arguments, `simctl.py` keeps one connection open and streams
commands from stdin. This preserves the ordering of mouse motion, button, and
keyboard packets:

```sh
printf '%s\n' \
  'mouse 0 0 1' \
  'mouse 10 -4 1' \
  'mouse 10 -4 1' \
  'mouse 0 0 0' | ./simctl.py
```

Commands are:

```text
mouse <dx> <dy> [buttons]
key <name> [press|down|up]
checkpoint
screenshot [path]
status
quit
```

PS/2 mouse Y is positive upward and negative downward. Mouse button bits are
left=1, right=2, and middle=4. The server binds to `127.0.0.1` by default; use
`--control-bind 0.0.0.0` only when control from another machine is intended.

## Periodic checkpoints

For long boot or application runs, save a bounded set of rotating checkpoints:

```sh
./obj_dir/Vz486_mister_sim \
  --disk /tmp/test.vhd \
  --checkpoint-dir /tmp/test-checkpoints \
  --checkpoint-interval-sec 30 \
  --checkpoint-keep 4
```

Restore the nearest checkpoint before a failure and trace only the remaining
window:

```sh
./obj_dir/Vz486_mister_sim \
  --restore /tmp/test-checkpoints/ckpt_0000000123611872 \
  --trace --trace-start 247300000 --end 263000000
```

The interval is wall-clock seconds. The checkpoint name and trace boundaries
use simulator time (`2 * cycle`). Each full-system checkpoint can consume
hundreds of megabytes, so keep retention bounded.
