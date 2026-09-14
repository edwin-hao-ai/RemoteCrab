#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/AudioServerPlugIn.h>

typedef void* (*FactoryFn)(CFAllocatorRef, CFUUIDRef);
static AudioServerPlugInDriverInterface **iface;
static void *inst;

#define STEP(...) do { printf(__VA_ARGS__); fflush(stdout); } while (0)

static OSStatus getSize(AudioObjectID obj, AudioObjectPropertySelector sel, UInt32 *out) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    return (*iface)->GetPropertyDataSize(inst, obj, 0, &a, 0, NULL, out);
}
static OSStatus getData(AudioObjectID obj, AudioObjectPropertySelector sel, UInt32 size, void *buf) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 got = size;
    return (*iface)->GetPropertyData(inst, obj, 0, &a, 0, NULL, size, &got, buf);
}

// mic-driver-harness.c — dlopen test bench for the iBridgeMicrophone HAL
// plug-in. Replays the exact call sequence observed in
// Core-Audio-Driver-Service (factory → QI → Release(factory) → use),
// then walks the property tree and the full host enumeration
// (dev#/clas/ring/uidd/RelatedDevices/PreferredChannelLayout).
// Build & run (from the repo root):
//   clang -arch x86_64 -o /tmp/mic-harness scripts/mic-driver-harness.c \
//     -framework CoreFoundation -framework CoreAudio
//   /tmp/mic-harness /path/to/iBridgeMicrophone   # binary inside the .driver
int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/Library/Audio/Plug-Ins/HAL/iBridgeMicrophone.driver/Contents/MacOS/iBridgeMicrophone";
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { STEP("dlopen FAILED: %s\n", dlerror()); return 1; }
    FactoryFn f = (FactoryFn)dlsym(h, "iBridgeMicrophone_Create");
    CFUUIDRef type = CFUUIDCreateFromString(NULL, CFSTR("443ABAB8-E7B3-491A-B985-BEB9187030DB"));
    inst = f(NULL, type);
    STEP("factory OK %p\n", inst);
    iface = (AudioServerPlugInDriverInterface **)inst;
    static char dummyHost[4096];
    STEP("Initialize: %d\n", (int)(*iface)->Initialize(inst, (AudioServerPlugInHostRef)dummyHost));


    void *qi = NULL;
    REFIID iid; memset(&iid, 0, sizeof iid);
    HRESULT hr = (*iface)->QueryInterface(inst, iid, &qi);
    STEP("QueryInterface: hr=%d ref=%p (must equal inst)\n", (int)hr, qi);
    if (qi != inst) { STEP("BAD QueryInterface ref\n"); return 1; }
    (*iface)->AddRef(inst);
    STEP("AddRef OK\n");
    // Host (get_asp_interface) releases the factory ref right after QI.
    // With a correct QI (AddRef) the driver must survive this.
    (*iface)->Release(inst);
    STEP("Release(factory) done — driver must still be alive\n");
    (*iface)->AddRef(inst);
    (*iface)->Release(inst);
    STEP("AddRef/Release on live driver OK\n");

    AudioObjectID dev = 0;
    STEP("CreateDevice: %d\n", (int)(*iface)->CreateDevice(inst, NULL, NULL, &dev));

    // Walk the property tree like coreaudiod does
    UInt32 sz = 0;
    OSStatus st;
    AudioObjectID objs[8] = {0};
    st = getSize(1, kAudioObjectPropertyOwnedObjects, &sz);
    STEP("plugIn OwnedObjects size: st=%d sz=%u\n", (int)st, sz);
    if (st == 0 && sz) {
        st = getData(1, kAudioObjectPropertyOwnedObjects, sz, objs);
        STEP("plugIn OwnedObjects: st=%d first=%u\n", (int)st, objs[0]);
    }
    AudioObjectID d = objs[0] ? objs[0] : 2;

    CFStringRef name = NULL;
    st = getSize(d, kAudioObjectPropertyName, &sz);
    STEP("device Name size: st=%d sz=%u\n", (int)st, sz);
    if (st == 0) { st = getData(d, kAudioObjectPropertyName, sizeof name, &name);
        STEP("device Name: st=%d\n", (int)st); if (name) CFShow(name); }

    CFStringRef uid = NULL;
    st = getData(d, kAudioDevicePropertyDeviceUID, sizeof uid, &uid);
    STEP("device UID: st=%d\n", (int)st); if (uid) CFShow(uid);

    UInt32 transport = 0;
    st = getData(d, kAudioDevicePropertyTransportType, sizeof transport, &transport);
    STEP("device TransportType: st=%d val=%u\n", (int)st, transport);

    AudioObjectID streams[4] = {0};
    st = getSize(d, kAudioDevicePropertyStreams, &sz);
    STEP("device Streams size: st=%d sz=%u scope=input\n", (int)st, sz);
    {   // streams are per-scope; query input scope explicitly
        AudioObjectPropertyAddress a = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
        st = (*iface)->GetPropertyDataSize(inst, d, 0, &a, 0, NULL, &sz);
        STEP("device Streams(input) size: st=%d sz=%u\n", (int)st, sz);
        if (st == 0 && sz) {
            UInt32 got = sz;
            st = (*iface)->GetPropertyData(inst, d, 0, &a, 0, NULL, sz, &got, streams);
            STEP("device Streams(input): st=%d first=%u\n", (int)st, streams[0]);
        }
    }
    AudioObjectID s = streams[0] ? streams[0] : 3;
    AudioStreamBasicDescription fmt; memset(&fmt, 0, sizeof fmt);
    st = getData(s, kAudioStreamPropertyVirtualFormat, sizeof fmt, &fmt);
    STEP("stream VirtualFormat: st=%d rate=%.0f ch=%u bits=%u\n", (int)st, fmt.mSampleRate, fmt.mChannelsPerFrame, fmt.mBitsPerChannel);

    // --- host enumeration replay (observed via Core-Audio-Driver-Service logs) ---
    {   // plugin: dev# (device list)
        AudioObjectPropertyAddress a = { 'dev#', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectID list[4] = {0}; UInt32 got = sizeof list;
        st = (*iface)->GetPropertyData(inst, 1, 0, &a, 0, NULL, sizeof list, &got, list);
        STEP("plugIn dev#: st=%d n=%u first=%u\n", (int)st, got/4, list[0]);
        if (st || list[0] != 2) { STEP("BAD dev#\n"); return 1; }
    }
    {   // clas on all objects
        AudioObjectPropertyAddress a = { 'clas', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioClassID c = 0; UInt32 got;
        for (AudioObjectID o = 1; o <= 3; o++) {
            got = sizeof c; c = 0;
            st = (*iface)->GetPropertyData(inst, o, 0, &a, 0, NULL, sizeof c, &got, &c);
            STEP("obj %u clas: st=%d val=%c%c%c%c\n", o, (int)st, (char)(c>>24),(char)(c>>16),(char)(c>>8),(char)c);
            if (st) { STEP("BAD clas\n"); return 1; }
        }
    }
    {   // ring on device
        AudioObjectPropertyAddress a = { 'ring', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 v = 0, got = sizeof v;
        st = (*iface)->GetPropertyData(inst, 2, 0, &a, 0, NULL, sizeof v, &got, &v);
        STEP("device ring: st=%d val=%u\n", (int)st, v);
        if (st) { STEP("BAD ring\n"); return 1; }
    }
    {   // uidd translate
        AudioObjectPropertyAddress a = { 'uidd', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        CFStringRef uid = CFSTR("com.ibridge.iBridgeMicrophone.device");
        AudioObjectID v = 0; UInt32 got = sizeof v;
        st = (*iface)->GetPropertyData(inst, 1, 0, &a, sizeof uid, &uid, sizeof v, &got, &v);
        STEP("plugIn uidd: st=%d val=%u\n", (int)st, v);
        if (st || v != 2) { STEP("BAD uidd\n"); return 1; }
    }
    {   // RelatedDevices + PreferredChannelLayout
        AudioObjectPropertyAddress a = { kAudioDevicePropertyRelatedDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectID v = 0; UInt32 got = sizeof v;
        st = (*iface)->GetPropertyData(inst, 2, 0, &a, 0, NULL, sizeof v, &got, &v);
        STEP("device RelatedDevices: st=%d val=%u\n", (int)st, v);
        if (st) { STEP("BAD RelatedDevices\n"); return 1; }
        AudioObjectPropertyAddress b = { kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt8 buf[128]; got = sizeof buf;
        st = (*iface)->GetPropertyData(inst, 2, 0, &b, 0, NULL, sizeof buf, &got, buf);
        STEP("device PreferredChannelLayout: st=%d sz=%u\n", (int)st, got);
        if (st) { STEP("BAD PreferredChannelLayout\n"); return 1; }
    }
    STEP("ALL OK\n");
    return 0;
}
