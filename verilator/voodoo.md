# PC+zSST (Voodoo) simulation

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
