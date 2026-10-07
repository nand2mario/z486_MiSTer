# 86Box CPU core: upstream and local changes

libcosim86.a (the MiSTer sim's `--cosim` reference, built by the Makefile
here) builds 86Box's `src/cpu` from the 86Box checkout at `./86Box`, a git
submodule: [nand2mario/86Box](https://github.com/nand2mario/86Box) branch
**z486-cosim**, upstream master **e18708b769 (2026-10-04)** with these
changes:

```
1593f9b cpu: GEN386PM_NO_FPU builds the CPU core without the FPU
07e310c cpu: XADD r, r writes DEST last
819686c cpu: SHLD/SHRD set OF on a 1-bit shift and read DEST for a 0 count
f4409a3 cpu: INVD is privileged
bb9ea70 cpu: iss_ss_chain switch for the MOV SS / POP SS interrupt shadow
99d7044 cpu: iss_sel_push32 switch for selectors in 32-bit frames
c231782 cpu: IRET does not load FLAGS bit 15
6d266fe cpu: lazy AF for ADC tests OP2's low nibble
79a6954 cpu: a 3-byte instruction at a page's end does not fetch the next page
20acafb cpu: DR7 bit 10 is set on writes only from the Pentium
```

Fetch it with `git submodule update --init verilator/cosim/86Box` (or clone
this repository with `--recursive`). Without a checkout, the MiSTer sim links
`libcosim86_stub.a` and `--cosim` reports that the reference is missing.

To resync with upstream: fetch upstream master into the checkout, rebase
z486-cosim onto it, rebuild, and check that a pinned co-simulation snapshot
runs without divergence.

## Kinds of change

Bugs in 86Box (candidates to report upstream):

* XADD r, r: the PRM writes DEST last (TEMP <- SRC + DEST; SRC <- DEST;
  DEST <- TEMP); 86Box overwrites it with SRC.
* SHLD/SHRD: OF is set on a 1-bit shift that changes the sign; 86Box never
  sets it.
* INVD is privileged (#GP above CPL 0, like WBINVD).
* IRET/IRETD (real mode, V86 and protected mode) loaded FLAGS bit 15, which
  is reserved and reads 0 on a 386/486 (MS-DOS tells an 8086 from a 386+ by
  it).
* Lazy AF for ADC tested the whole operand for all ones and lost AF (e.g.
  FEh + 1Fh + CF=1); it tests OP2's low nibble.
* fastreadl_fetch: a 3-byte instruction at a page's last three bytes read a
  word at +2, touching the next page (a spurious fetch page fault); it reads
  a byte.
* MOV DR7 set bit 10 on every write; a 386/486 resets DR7 to 0 (i486 PRM
  Table 10-1) and keeps a written bit 10 as written (Links 386 Pro's DOS
  extender saves and restores DR7).
* Not changed in the CPU sources but handled in our glue: faults do not set
  RF in the pushed EFLAGS image and RF is never cleared when an instruction
  completes (i486 PRM 9.3.3, 11.3.1.1); POP r assigns before its fault
  check (the glue undoes faulting instructions).

Co-simulation switches and choices that follow z486 (keep on our branch):

* `GEN386PM_NO_FPU` stubs the FPU escape ops (the reference has no FPU).
* `iss_ss_chain`: MOV SS / POP SS run the next instruction within the op
  (86Box's interrupt shadow) only when set; cosim86 clears it to step one
  instruction at a time.
* `iss_sel_push32`: selectors in 32-bit interrupt and gate frames are
  written as zero-extended dwords, as z486's 386 microcode does; 86Box
  writes 16 bits.
* SHLD/SHRD read the destination before testing a 0 count, as the 386
  microcode does (a memory operand can fault); the PRM leaves it open.
* `iss_split_write_first` (glue, `stubs.c`): a write split across pages
  stores its first page's bytes before the second page is translated, as
  z486's paging unit sends a split access's first bus cycle before
  translating the second; 86Box checks both pages first. Seen as a REP STOSD
  element faulting on its second page in Windows 95. MOVS/STOS probe the
  destination first in 86Box, so cosim86 stores that part when the probe's
  fault is delivered (split_string_store).
* Shift/rotate of memory by 0 (glue, `cosim86.c`): z486's 386 microcode
  still writes the operand back unchanged; 86Box writes nothing. cosim86
  records the same bytes as silent writes (seen in Beneath a Steel Sky's
  protection code, ROL BYTE [BX+SI],0).
* ENTER (glue, `cosim86.c`): the 386 microcode pushes EBP, then probes the
  final ESP (CW) before committing it, so a not-present stack page faults in
  ENTER with its pushes in memory (PRM: ENTER checks the stack limit "at any
  point during instruction execution"); 86Box faults in the next push.
  cosim86 probes the final ESP after ENTER and keeps the pushes.

## Our glue (this directory)

`cosim86.c`/`cosim86.h` (the co-simulation API), `cosim86_stub.c`,
`iss_glue.h`, `stubs.c` (flat memory with a paging
translation hook, weak exception entry points, `do_seg_load`, wait-state
globals) and the trimmed `include/86box/` headers (`mem.h`: `RAM_SIZE`,
`is_compare`; `86box.h`: `LIKELY`/`UNLIKELY`). Because they link 86Box code
(GPL-2.0-or-later), they are released under the same licence.
