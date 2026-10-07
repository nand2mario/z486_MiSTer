/* Stub timer.h for standalone gen386pm */
#ifndef _86BOX_TIMER_H
#define _86BOX_TIMER_H

#include <stdint.h>

extern uint64_t timer_target;
extern uint64_t tsc;

#define TIMER_VAL_LESS_THAN_VAL(a, b) ((a) < (b))

#define timer_process() ((void)0)

#endif /* _86BOX_TIMER_H */
