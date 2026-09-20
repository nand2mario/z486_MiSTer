# z486 MiSTer Verilator harness

This is a whole system simulator of z486_MiSTer backed by the RTL (SystemVerilog
code) and can be used to debug the system or study how an x86 machine works.
On a modern PC or Mac, this generally runs at about 0.2-0.5MHz, i.e. ~1% of a
real 486. It boots DOS in about one minute and reaches the Windows 95 desktop
in roughly half an hour.

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

## Running a simulation

You can start a simulation with a VHD flat hard disk image like this:

```sh
./obj_dir/Vz486_mister_sim --disk /tmp/dos622.vhd
```

The simulator supports VGA output of both text modes and graphics mode. And the
main window supports keyboard input so you can interact with the machine,
albeit very slowly.

Times on the command line are sim time, which is twice the CPU cycle count.
Useful options include:
* `--headless`: run without the SDL window (for scripted and long runs).
* `--end <sim_time>`: stop at this time.
* `--trace`: write an FST waveform (`waveform.fst`, or `--trace-file path`);
  `--trace-start <sim_time>` starts it later.
* `--floppy <img>`: mount a floppy image as A:.
* `--cdrom <iso>`: mount a CD-ROM ISO image.
* `--boot0 <rom>`, `--boot1 <rom>`: the system BIOS and VGA BIOS (default
  `boot0.rom` and `boot1.rom` in the current directory).
* `--ram-mb 16|32|64|128`: memory size (default 64, the OSD default).
* `+z486_x87_off`: run without the FPU, like the core's x87 Off switch.
* `--screenshot-dir <dir> --screenshot-interval <sim_time>`: save the screen
  periodically; `--stop-on-text <s>` stops when text mode shows `s`.
* `--key-at <sim_time>:<key>`, `--mouse-at <sim_time>:<dx>:<dy>[:<buttons>]`:
  scripted input; see also the control socket below.
* `--rtc "YYYY-MM-DD HH:MM:SS"`: CMOS clock start (default host local time).
* `--no-audio-clock`: about 10% faster; stops the OPL3 and the audio output.

Run with `--help` for the full list.

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

## Live control socket

Start the simulator with a localhost TCP control socket:

```sh
./obj_dir/Vz486_mister_sim --disk win311_auto.vhd --control-port 9386
```

Send a single command with `simctl.py`:

```sh
./simctl.py status
./simctl.py mouse -20 -40 0
./simctl.py key enter
./simctl.py screenshot /tmp/z486.png
./simctl.py checkpoint
```

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

## Co-simulation against 86Box

For longer debugging runs, we use co-simulation, a powerful method for CPU
verification. Co-simulation runs the RTL CPU and a trusted instruction-set
model side by side on the same program and compares them after every
instruction, so a bug is caught at the first instruction whose result differs
rather than millions of instructions later when the OS crashes. It is the
lockstep form of [differential
testing](https://en.wikipedia.org/wiki/Differential_testing), used widely in
CPU verification; Esperanto's
[Dromajo](https://github.com/chipsalliance/dromajo), a RISC-V reference model
built for RTL co-simulation with checkpoint/resume, is a good overview of the
approach. Here the reference is the 86Box emulator and the workload is a whole
PC: BIOS, DOS, Windows and applications from real disk images.

`--cosim` runs 86Box's CPU core in lockstep with z486 and stops at the first
difference. The reference is built from an 86Box checkout at `cosim/86Box`
(our branch z486-cosim; see [cosim/UPSTREAM.md](cosim/UPSTREAM.md)) together
with the glue in `cosim/` as `libcosim86.a`; without the checkout the
simulator still builds but `--cosim` is unavailable. It checks the EIP of
every issued instruction, every memory and I/O write, and the general
registers; z486 supplies I/O and A0000-BFFFF read data, interrupt vectors, DMA
writes and page-walk A/D updates, so peripheral bugs show as hangs, not
divergences.

```sh
make no_x87
./obj_dir_no_x87/Vz486_mister_sim --headless --cosim --no-audio-clock \
  --ram-mb 64 --disk win95.vhd \
  --snapshot-dir /data/snap/run1 --snapshot-keep 200 \
  --screenshot-dir /tmp/shots --screenshot-interval 20000000 \
  --control-port 5995
```

On a divergence the run prints the reference's last instructions
(`COSIM_HIST=n` for up to 64), its unmatched writes and z486's last writes.
`COSIM_TRACE=1` logs interrupts and I/O/device reads. To get an FST trace of
the divergence, restore the last snapshot before it (`snap_<cycle>`, at sim
time 2 × cycle) with the same arguments and `--end` a little past
the reported time. A restore does not repeat the cycle timing, so the
divergence may come somewhat later (100 to 15000 sim time so far): 
rerun with `--trace-start` a few thousand before it,
`--trace-file`, and `--end` just after it. The trace stays small and covers
the instructions leading up to the difference.

### Portable snapshots

To facilitate co-simulation of long sessions like Windows or games, there is a
"snapshot" mechanism that allows continuation of simulation even after RTL
changes. It works by saving the machine at the architectural level rather than
as the simulator's internal state. The CPU is restored from what software can
see (registers, segment descriptors, control registers), taken from the 86Box
reference, while its microarchitecture (pipeline, caches, TLB) starts from
reset, so a rebuilt z486 with different RTL can pick up where the old one
stopped. Peripherals are saved by hierarchical name and restored field by
field; fields that a new build added or removed are reported and left at
reset. Memory and disk are saved as differences from a base, which keeps a
snapshot to about 0.5 MB.

Use checkpoints (`--checkpoint-dir`, `--restore`) instead when a run must
replay cycle for cycle on the same binary, for example a timing-dependent bug,
or without `--cosim`. A snapshot repeats the same instructions but not the
same cycle timing just after the restore, so a bug that depends on cache, TLB
or in-flight pipeline state may need an earlier snapshot to reappear.

`--snapshot-dir` saves a snapshot every 60 s (`--snapshot-interval-sec`) at
an instruction boundary: non-CPU model state by name, the CPU's architectural
state from the reference, RAM as keyframe plus page diff, and the disk as the
sectors that differ from the image. Snapshots restore into builds with
changed CPU RTL:

```sh
./obj_dir_no_x87/Vz486_mister_sim --headless --cosim --no-audio-clock --ram-mb 64 \
  --disk /data/c.vhd --cdrom /data/cd.iso \
  --restore-snapshot /data/snap/run1/snap_0000004800648979 \
  --trace --trace-start 9601300000 --trace-file /tmp/x.fst --end 9602000000
```

Pass the same image arguments as the original run. Only the last
`--snapshot-keep` snapshots are kept; keep important points with

```sh
./pin_snapshot.py /data/snap/run1/snap_0000004800648979 my_point "note" --run "<args>"
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

## SVGA framebuffer formats

The simulator defaults to the MiSTer core's BGR/1555 framebuffer settings.
Use `--fb-rgb` or `--fb-565` to test software that expects the alternate channel
order or 16-bit format; `--fb-bgr` and `--fb-1555` restore the defaults.

## PC+zSST simulation

See [voodoo.md](voodoo.md) for the whole-PC Voodoo (zSST) build and trace
capture.

