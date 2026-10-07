/* Stub plat_fallthrough.h for standalone gen386pm */
#ifndef _86BOX_PLAT_FALLTHROUGH_H
#define _86BOX_PLAT_FALLTHROUGH_H

#if defined(__GNUC__) && __GNUC__ >= 7
#define fallthrough __attribute__((fallthrough))
#else
#define fallthrough ((void)0)
#endif

#endif
