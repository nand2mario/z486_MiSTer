/* Stub mem.h for standalone gen386pm */
#ifndef _86BOX_MEM_H
#define _86BOX_MEM_H

#include <stdint.h>

/* Memory access functions - implemented in stubs.c */
extern uint8_t  readmembl_2386(uint32_t addr);
extern void     writemembl_2386(uint32_t addr, uint8_t val);
extern uint16_t readmemwl_2386(uint32_t addr);
extern void     writememwl_2386(uint32_t addr, uint16_t val);
extern uint32_t readmemll_2386(uint32_t addr);
extern void     writememll_2386(uint32_t addr, uint32_t val);
extern uint64_t readmemql_2386(uint32_t addr);
extern void     writememql_2386(uint32_t addr, uint64_t val);

/* No-MMU variants (same as above for our flat model) */
extern uint8_t  readmembl_no_mmut_2386(uint32_t addr, uint32_t a64);
extern void     writemembl_no_mmut_2386(uint32_t addr, uint32_t a64, uint8_t val);
extern uint16_t readmemwl_no_mmut_2386(uint32_t addr, uint32_t *a64);
extern void     writememwl_no_mmut_2386(uint32_t addr, uint32_t *a64, uint16_t val);
extern uint32_t readmemll_no_mmut_2386(uint32_t addr, uint32_t *a64);
extern void     writememll_no_mmut_2386(uint32_t addr, uint32_t *a64, uint32_t val);

/* MMU translate stub - always identity mapping for flat memory.
 * In 86Box the signature varies (uint32_t vs uint32_t*), so we just
 * make the do_mmut_* macros no-ops since we don't need MMU translation. */

/* RAM mask */
extern uint32_t rammask;

/* read_type used by fastread* functions in 386_common.h */
extern int read_type;

/* Memory debugging stubs */
#define mem_debug_check_addr(a, t) ((void)0)

/* flushmmucache - no-op for flat memory */
#define flushmmucache()     ((void)0)
#define flushmmucache_cr3() ((void)0)
#define flushmmucache_pc()  ((void)0)

/* Code generation stubs */
extern uint32_t pccache;
extern uint8_t *pccache2;

extern uint8_t *getpccache(uint32_t a);

/* RAM size constant */
#define RAM_SIZE (16 * 1024 * 1024)

/* RAM access */
extern uint8_t *ram;
extern uint32_t mem_size;

#define nmi_mask 1

/* Set while CMPS/SCAS run their accesses (upstream mem.c). */
extern int is_compare;

#endif /* _86BOX_MEM_H */
