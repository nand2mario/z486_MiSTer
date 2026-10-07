/* Stub io.h for standalone gen386pm */
#ifndef _86BOX_IO_H
#define _86BOX_IO_H

#include <stdint.h>

/* IO stubs - implemented in stubs.c */
extern uint8_t  inb(uint16_t port);
extern uint16_t inw(uint16_t port);
extern uint32_t inl(uint16_t port);
extern void     outb(uint16_t port, uint8_t val);
extern void     outw(uint16_t port, uint16_t val);
extern void     outl(uint16_t port, uint32_t val);

#endif /* _86BOX_IO_H */
