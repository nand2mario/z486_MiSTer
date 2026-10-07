/* Stub 86box.h for standalone gen386pm test generator */
#ifndef _86BOX_86BOX_H
#define _86BOX_86BOX_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Logging stubs */
#define pclog_ex(fmt, ap) ((void)0)
#define pclog(...)        ((void)0)
#define fatal(...)        do { fprintf(stderr, __VA_ARGS__); abort(); } while(0)

/* Compiler helpers */
#ifndef UNUSED
#define UNUSED(x) ((void)(x))
#endif

/* FPU_CYCLES intentionally NOT defined here - must be defined after cpu.h */

/* Min/Max */
#ifndef MIN
#define MIN(a,b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#endif

/* Endianness helpers */
#define AS_U32(x) (*(uint32_t *)&(x))

/* Config stubs */
#define machine_at 1

#ifdef __GNUC__
#    define UNLIKELY(x) __builtin_expect(!!(x), 0)
#    define LIKELY(x)   __builtin_expect(!!(x), 1)
#else
#    define UNLIKELY(x) (x)
#    define LIKELY(x)   (x)
#endif

#endif /* _86BOX_86BOX_H */
