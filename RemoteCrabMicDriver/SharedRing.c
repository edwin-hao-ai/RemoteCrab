#include "SharedRing.h"

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

void IBRingInit(IBRing *ring) {
    if (!ring) return;
    atomic_init(&ring->writeFrame, 0);
    atomic_init(&ring->readFrame, 0);
    ring->sampleRate = 48000;
    ring->channels = IB_RING_CHANNELS;
    memset(ring->samples, 0, sizeof ring->samples);
}

IBRing *IBRingOpen(void) {
    char name[64];
    snprintf(name, sizeof name, "/remotecrab-mic-%d", (int)getuid());

    int fd = shm_open(name, O_CREAT | O_RDWR, 0644);
    if (fd < 0) return NULL;
    if (ftruncate(fd, (off_t)sizeof(IBRing)) != 0) {
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, sizeof(IBRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return NULL;

    IBRing *ring = (IBRing *)p;
    /* First creator stamps the format; both sides read it. */
    if (ring->sampleRate == 0) {
        ring->sampleRate = 48000;
        ring->channels = IB_RING_CHANNELS;
    }
    return ring;
}

int64_t IBRingWrite(IBRing *ring, const int16_t *src, int64_t frames) {
    if (!ring || !src || frames <= 0) return 0;
    int64_t w = atomic_load_explicit(&ring->writeFrame, memory_order_relaxed);
    for (int64_t i = 0; i < frames; i++) {
        ring->samples[(w + i) % IB_RING_FRAMES] = src[i];
    }
    atomic_store_explicit(&ring->writeFrame, w + frames, memory_order_release);
    return frames;
}

void IBRingRead(IBRing *ring, int16_t *dst, int64_t frames) {
    if (!ring || !dst || frames <= 0) return;
    int64_t w = atomic_load_explicit(&ring->writeFrame, memory_order_acquire);
    int64_t r = atomic_load_explicit(&ring->readFrame, memory_order_relaxed);

    /* Drop the oldest data on overrun so we never read into the void. */
    if (w - r > IB_RING_FRAMES) r = w - IB_RING_FRAMES;
    int64_t available = w - r;
    if (available < 0) available = 0;

    int64_t n = frames < available ? frames : available;
    for (int64_t i = 0; i < n; i++) {
        dst[i] = ring->samples[(r + i) % IB_RING_FRAMES];
    }
    for (int64_t i = n; i < frames; i++) dst[i] = 0;

    atomic_store_explicit(&ring->readFrame, r + n, memory_order_release);
}

int32_t IBRingSampleRate(IBRing *ring) {
    if (!ring || ring->sampleRate == 0) return 48000;
    return ring->sampleRate;
}
