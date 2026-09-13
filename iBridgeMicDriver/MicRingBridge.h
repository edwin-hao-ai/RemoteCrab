//
//  MicRingBridge.h
//  Swift-friendly (opaque) wrapper over the C ring in SharedRing.h, so
//  the Mac app can feed the HAL driver without importing stdatomic.
//

#ifndef IBRIDGE_MIC_RING_BRIDGE_H
#define IBRIDGE_MIC_RING_BRIDGE_H

#include <stdint.h>

/// Open (creating if needed) the per-user ring; NULL on failure.
void *IBMicRingOpen(void);

/// Append mono Int16 samples.
void IBMicRingWrite(void *ring, const int16_t *src, int64_t frames);

#endif /* IBRIDGE_MIC_RING_BRIDGE_H */
