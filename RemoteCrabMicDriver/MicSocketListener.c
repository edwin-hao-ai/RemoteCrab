#include "MicSocketListener.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

struct IBMicSocketListener {
    IBRing *ring;
    int sock;
    pthread_t thread;
    _Atomic int stop;
};

static void *listenerMain(void *ctx) {
    IBMicSocketListener *listener = (IBMicSocketListener *)ctx;
    /* One datagram = one chunk of mono Int16 PCM (the app sends
     * 20 ms = 960 frames; 4096 frames covers any plausible burst). */
    int16_t buf[4096];
    while (!atomic_load_explicit(&listener->stop, memory_order_acquire)) {
        ssize_t n = recvfrom(listener->sock, buf, sizeof buf, 0, NULL, NULL);
        if (n <= 0) continue; /* timeout tick or transient error */
        IBRingWrite(listener->ring, buf, n / (ssize_t)sizeof(int16_t));
    }
    return NULL;
}

IBMicSocketListener *IBMicSocketListenerStart(IBRing *ring) {
    if (!ring) return NULL;

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) return NULL;

    /* SO_REUSEADDR so a coreaudiod restart can rebind immediately. */
    int yes = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);

    /* Don't block in recvfrom forever: the stop flag must be polled.
     * 200 ms is far below anything audible (the ring holds 2 s). */
    struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (void *)&tv, sizeof tv);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_len = sizeof addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(IB_MIC_UDP_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(sock, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(sock);
        return NULL;
    }

    IBMicSocketListener *listener = (IBMicSocketListener *)calloc(1, sizeof(IBMicSocketListener));
    if (!listener) {
        close(sock);
        return NULL;
    }
    listener->ring = ring;
    listener->sock = sock;
    atomic_init(&listener->stop, 0);
    if (pthread_create(&listener->thread, NULL, listenerMain, listener) != 0) {
        close(sock);
        free(listener);
        return NULL;
    }
    return listener;
}

void IBMicSocketListenerStop(IBMicSocketListener *listener) {
    if (!listener) return;
    atomic_store_explicit(&listener->stop, 1, memory_order_release);
    pthread_join(listener->thread, NULL);
    close(listener->sock);
    free(listener);
}
