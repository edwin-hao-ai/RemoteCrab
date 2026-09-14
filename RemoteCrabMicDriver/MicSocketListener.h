//
//  MicSocketListener.h
//  Loopback-UDP feed into the mic ring. The sandboxed app cannot
//  shm_open into coreaudiod's process, so it datagrams raw Int16 PCM to
//  127.0.0.1:49182 instead (loopback UDP is allowed by the app sandbox).
//  This listener runs inside the HAL plug-in and is the single writer
//  to the ring; the IO thread stays the single reader — the ring's
//  SPSC design is unchanged.
//

#ifndef REMOTECRAB_MIC_SOCKET_LISTENER_H
#define REMOTECRAB_MIC_SOCKET_LISTENER_H

#include "SharedRing.h"

#define IB_MIC_UDP_PORT 49182

typedef struct IBMicSocketListener IBMicSocketListener;

/// Bind 127.0.0.1:IB_MIC_UDP_PORT and spawn the recv thread feeding
/// `ring`. Returns NULL on failure — the device then outputs silence,
/// same as "app not running".
IBMicSocketListener *IBMicSocketListenerStart(IBRing *ring);

/// Stop the thread and close the socket. Safe to call with NULL.
void IBMicSocketListenerStop(IBMicSocketListener *listener);

#endif /* REMOTECRAB_MIC_SOCKET_LISTENER_H */
