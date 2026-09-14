//
//  SharedRing.h
//  Shared, lock-free single-producer/single-consumer audio ring between
//  the iBridge Mac app (writer) and the iBridgeMicrophone HAL plug-in
//  (reader, running inside coreaudiod). Plain C + stdatomic so both the
//  C plug-in and Swift (via a bridging header) can use it safely.
//

#ifndef IBRIDGE_SHARED_RING_H
#define IBRIDGE_SHARED_RING_H

#include <stdint.h>
#include <stdatomic.h>

#define IB_RING_FRAMES 96000    /* 2 s @ 48 kHz mono */
#define IB_RING_CHANNELS 1

typedef struct {
    _Atomic int64_t writeFrame;   /* samples written by the app   */
    _Atomic int64_t readFrame;    /* samples consumed by the driver */
    int32_t sampleRate;
    int32_t channels;
    int16_t samples[IB_RING_FRAMES * IB_RING_CHANNELS];
} IBRing;

/// Initialize a caller-owned (e.g. heap) ring in place. The HAL plug-in
/// uses this: the sandboxed app can't reach a POSIX shm segment, so the
/// ring lives inside coreaudiod and the app feeds it over loopback UDP
/// (see MicSocketListener.c). `IBRingOpen` remains for non-sandboxed
/// consumers that can share memory directly.
void IBRingInit(IBRing *ring);

/// Open (creating if needed) the per-user shared ring. Safe to call
/// from either process. Returns NULL on failure.
IBRing *IBRingOpen(void);

/// Writer: append mono Int16 samples. Old samples are overwritten once
/// the ring wraps. Returns the number of frames written.
int64_t IBRingWrite(IBRing *ring, const int16_t *src, int64_t frames);

/// Reader: copy `frames` mono Int16 samples, zero-filling any underrun.
void IBRingRead(IBRing *ring, int16_t *dst, int64_t frames);

/// Sample rate advertised by the writer (defaults to 48000).
int32_t IBRingSampleRate(IBRing *ring);

#endif /* IBRIDGE_SHARED_RING_H */
