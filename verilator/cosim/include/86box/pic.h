/* Stub pic.h for standalone gen386pm */
#ifndef _86BOX_PIC_H
#define _86BOX_PIC_H

#include <stdint.h>

typedef struct {
    int int_pending;
} pic_t;

extern pic_t pic, pic2;

static inline int picinterrupt(void) { return -1; }

#endif /* _86BOX_PIC_H */
