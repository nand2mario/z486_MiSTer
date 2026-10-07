# libcosim86.a: 86Box's CPU core as the reference for the MiSTer sim's
# --cosim. The core is src/cpu of an 86Box checkout at ./86Box (branch
# z486-cosim; see UPSTREAM.md). libcosim86_stub.a stands in when there is no
# checkout: the simulator builds and --cosim reports that it is unavailable.

CC := gcc
BOX86 ?= 86Box
CPU := $(BOX86)/src/cpu
CFLAGS := -O2 -g -Wall -Wno-unused-variable -Wno-unused-function \
          -Wno-unused-but-set-variable -Wno-sign-compare \
          -Wno-parentheses -Wno-missing-braces \
          -Wno-implicit-function-declaration \
          -DOPS_286_386 -DGEN386PM_NO_FPU -DUSE_NEW_DYNAREC \
          -I. -Iinclude -I$(CPU)

COSIM_SRCS := cosim86.c stubs.c x86seg_common.c x86seg.c
COSIM_OBJS := $(COSIM_SRCS:%.c=obj/%.o)
HDRS := $(wildcard *.h include/86box/*.h) $(wildcard $(CPU)/*.h)
vpath %.c $(CPU)

.PHONY: all clean
all: libcosim86.a

obj/%.o: %.c $(HDRS)
	@mkdir -p obj
	$(CC) $(CFLAGS) -c -o $@ $<

libcosim86.a: $(COSIM_OBJS)
	ar rcs $@ $^

libcosim86_stub.a: cosim86_stub.c cosim86.h
	@mkdir -p obj
	$(CC) -O2 -Wall -I. -c -o obj/cosim86_stub.o cosim86_stub.c
	ar rcs $@ obj/cosim86_stub.o

clean:
	rm -rf obj libcosim86.a libcosim86_stub.a
