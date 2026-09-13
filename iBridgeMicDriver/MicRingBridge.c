#include "MicRingBridge.h"
#include "SharedRing.h"

void *IBMicRingOpen(void) {
    return (void *)IBRingOpen();
}

void IBMicRingWrite(void *ring, const int16_t *src, int64_t frames) {
    IBRingWrite((IBRing *)ring, src, frames);
}
