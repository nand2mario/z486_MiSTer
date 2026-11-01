# z486 MiSTer core

z486_MiSTer is an experimental PC core for MiSTer built around the
[z486 CPU](https://github.com/nand2mario/z486), an 80486-class pipelined FPGA
CPU written in SystemVerilog. The processor combines a fast frontend and
hardwired implementations of common instructions with microcoded control for
complex x86 operations. It also includes experimental, incomplete x87 support
sufficient to run TurboQuake.

The core delivers roughly 486DX2-66-class performance. It runs the Doom
timedemo at 29.1 FPS at maximum detail, compared with 21.0 FPS on ao486 using
the same MiSTer setup.

The core uses MiSTer SDRAM for system memory and supports 16, 32, 64, or 128 MB
configurations. Video hardware provides VGA and ET4000-compatible SVGA modes.

## Trying It

z486_MiSTer requires an SDRAM module. The SDRAM XS-D v2.5 module has been
verified to work. It also requires MiSTer main `MiSTer_20260823` or newer;
run `Scripts` → `update` before installing the core.

Download the latest build from the
[releases page](https://github.com/nand2mario/z486_MiSTer/releases), then place
the files as follows:

- `z486_*.rbf` in `/media/fat/_Computer`
- [boot0.rom](verilator/boot0.rom), [boot1.rom](verilator/boot1.rom), and disk
  images (`.vhd`) in `/media/fat/games/Z486`

Development and compatibility discussion is available in the
[MiSTer FPGA forum thread](https://misterfpga.org/viewtopic.php?t=10667).

## Serial port

COM3 is a 16550A at `3E8h`, IRQ 4. It connects to the MiSTer UART when the core's UART connection is set to PPP, Modem or Console. At 115200 baud or below, the guest's divisor must match the configured speed. Faster link speeds act as turbo, so a guest setting of 115200 runs at the link speed. MIDI mode keeps the UART for MPU-401 output. MT32-pi on the user port and the PS/2 mouse (IRQ 12) work in every mode.

To use the MiSTer virtual modem, set the UART connection to Modem and choose a baud rate, then configure your DOS communications program for COM3 (`3E8h`, IRQ 4) at that same rate. Modem mode uses the UART, so MidiLink MIDI output is unavailable while it is selected.

## Shared folders and CPU speed

[MISTERFS](doc/misterfs.md) shares `/media/fat/games/Z486/shared` with DOS using the current ao486 driver. If using EMM386, reserve `CE00-CFFF` before loading the driver.

The OSD offers Full, 56, 30, 15, 6, 5, 4 and 3 MHz-equivalent execution rates. Existing four-speed SYSCTL commands remain compatible; use the OSD for the four new rates. The [SYSCTL interface](doc/sysctl.md) documents core/version detection for future utility updates.
