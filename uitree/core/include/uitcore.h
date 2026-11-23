/* uitcore.h: the C ABI between the uitree core (Zig, libuitcore) and a
 * renderer (GPUI in Rust, the terminal in Zig).
 *
 * Status: scaffold. The spike (workstream W0) writes the real header from
 * the sketch in the scoping doc and freezes it as version 1. Until then
 * only the version call exists. See ../ARCHITECTURE.md for the threading
 * and ownership rules every function follows.
 */
#ifndef UITCORE_H
#define UITCORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UIT_ABI_VERSION 0u

/* The ABI version libuitcore was built with. A renderer checks it equals
 * UIT_ABI_VERSION at startup and refuses to run otherwise. */
uint32_t uit_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* UITCORE_H */
