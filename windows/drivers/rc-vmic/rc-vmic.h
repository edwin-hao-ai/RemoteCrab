/*++
    RemoteCrab virtual microphone driver (rc-vmic) — declarations.

    A **capture-only** PortCls WaveRT miniport that exposes a Windows capture
    endpoint named "RemoteCrab Microphone", fed from the byte ring the receiver
    writes (layout: windows/crates/rc-vmic/src/shm.rs).

    Adapted from Microsoft's sysvad (Windows-driver-samples, MS-PL), cut to a
    single capture pin. See README.md for the contract and the current status
    (**skeleton** — the PortCls plumbing is incomplete; not signed or run).

    The interface methods are declared explicitly rather than via the WDK's
    `IMP_*` macros: those expand to non-virtual `STDMETHODIMP_` members, which
    hide rather than override the interfaces' pure virtuals and leave the class
    abstract.
--*/

#pragma once

#include <portcls.h>
#include <ksmedia.h>
#include <stdunk.h>

// ---------------------------------------------------------------------------
// Ring reader (kernel side): maps %ProgramData%\RemoteCrab\vmic-ring.bin and
// drains it. The header is 64 bytes; see rc-vmic/src/shm.rs for the layout.
// ---------------------------------------------------------------------------
class CRingReader
{
public:
    CRingReader();
    ~CRingReader();

    NTSTATUS Open();
    void Close();
    bool IsOpen() const { return m_pBase != nullptr; }

    // Bytes currently readable (write_pos - read_pos), capped at Capacity.
    ULONG Available() const;

    // Copy up to `Bytes` bytes of PCM into Dst and advance read_pos in the
    // header. Returns the number copied; the caller silences the rest.
    ULONG Read(_Out_writes_bytes_(Bytes) BYTE* Dst, ULONG Bytes);

private:
    BYTE*   m_pBase;
    ULONG   m_Capacity;
    HANDLE  m_hFile;
    HANDLE  m_hSection;
    PVOID   m_pMapped;
    SIZE_T  m_ViewSize;
};

// ---------------------------------------------------------------------------
// One capture stream.
// ---------------------------------------------------------------------------
class CMiniportWaveRTStream : public IMiniportWaveRTStream,
                              public IMiniportWaveRTInputStream,
                              public CUnknown
{
public:
    // INonDelegatingUnknown / IUnknown
    STDMETHOD_(NTSTATUS, NonDelegatingQueryInterface)(_In_ REFIID iid, _COM_Outptr_ PVOID* ppv);
    STDMETHOD_(NTSTATUS, QueryInterface)(_In_ REFIID riid, _COM_Outptr_ void** ppv)
    {
        return GetOuterUnknown()->QueryInterface(riid, ppv);
    }
    STDMETHOD_(ULONG, AddRef)() { return GetOuterUnknown()->AddRef(); }
    STDMETHOD_(ULONG, Release)() { return GetOuterUnknown()->Release(); }

    CMiniportWaveRTStream(_In_opt_ PUNKNOWN UnknownOuter,
                          _In_opt_ PRESOURCELIST ResourceList,
                          _In_ ULONG Channels,
                          _In_ ULONG SampleRate);
    ~CMiniportWaveRTStream();

    // IMiniportWaveRTStream
    STDMETHOD_(NTSTATUS, SetFormat)(_In_ PKSDATAFORMAT DataFormat);
    STDMETHOD_(NTSTATUS, SetState)(_In_ KSSTATE State);
    STDMETHOD_(NTSTATUS, GetPosition)(_Out_ PKSAUDIO_POSITION Position);
    STDMETHOD_(NTSTATUS, AllocateAudioBuffer)(
        _In_ ULONG RequestedSize, _Out_ PMDL* AudioBufferMdl, _Out_ ULONG* ActualSize,
        _Out_ ULONG* OffsetFromFirstPage, _Out_ MEMORY_CACHING_TYPE* CacheType);
    STDMETHOD_(VOID, FreeAudioBuffer)(_In_opt_ PMDL AudioBufferMdl, _In_ ULONG BufferSize);
    STDMETHOD_(VOID, GetHWLatency)(_Out_ KSRTAUDIO_HWLATENCY* hwLatency);
    STDMETHOD_(NTSTATUS, GetPositionRegister)(_Out_ KSRTAUDIO_HWREGISTER* Register);
    STDMETHOD_(NTSTATUS, GetClockRegister)(_Out_ KSRTAUDIO_HWREGISTER* Register);

    // IMiniportWaveRTInputStream
    STDMETHOD_(NTSTATUS, GetReadPacket)(_Out_ ULONG* PacketNumber, _Out_ DWORD* Flags,
                                        _Out_ ULONG64* PerformanceCounterValue, _Out_ BOOL* MoreData);

private:
    CRingReader m_Ring;
    ULONG       m_Channels;
    ULONG       m_SampleRate;
    ULONG       m_BufferSize;
    BYTE*       m_Buffer;
    KSSTATE     m_State;
};

// ---------------------------------------------------------------------------
// The miniport (capture-only).
// ---------------------------------------------------------------------------
class CMiniportWaveRT : public IMiniportWaveRT, public CUnknown
{
public:
    // INonDelegatingUnknown / IUnknown
    STDMETHOD_(NTSTATUS, NonDelegatingQueryInterface)(_In_ REFIID iid, _COM_Outptr_ PVOID* ppv);
    STDMETHOD_(NTSTATUS, QueryInterface)(_In_ REFIID riid, _COM_Outptr_ void** ppv)
    {
        return GetOuterUnknown()->QueryInterface(riid, ppv);
    }
    STDMETHOD_(ULONG, AddRef)() { return GetOuterUnknown()->AddRef(); }
    STDMETHOD_(ULONG, Release)() { return GetOuterUnknown()->Release(); }

    CMiniportWaveRT(_In_opt_ PUNKNOWN UnknownOuter, _In_opt_ PRESOURCELIST ResourceList);
    ~CMiniportWaveRT();

    // IMiniport
    STDMETHOD_(NTSTATUS, GetDescription)(_Out_ PPCFILTER_DESCRIPTOR* Description);
    STDMETHOD_(NTSTATUS, DataRangeIntersection)(
        _In_ ULONG PinId, _In_ PKSDATARANGE DataRange, _In_ PKSDATARANGE MatchingDataRange,
        _In_ ULONG OutputBufferLength,
        _Out_writes_bytes_to_opt_(OutputBufferLength, *ResultantFormatLength)
            PVOID ResultantFormat,
        _Out_ PULONG ResultantFormatLength);

    // IMiniportWaveRT
    STDMETHOD_(NTSTATUS, Init)(_In_ PUNKNOWN UnknownAdapter, _In_ PRESOURCELIST ResourceList,
                               _In_ PPORTWAVERT Port);
    STDMETHOD_(NTSTATUS, NewStream)(_Out_ PMINIPORTWAVERTSTREAM* Stream,
                                    _In_ PPORTWAVERTSTREAM PortStream, _In_ ULONG Pin,
                                    _In_ BOOLEAN Capture, _In_ PKSDATAFORMAT DataFormat);
    STDMETHOD_(NTSTATUS, GetDeviceDescription)(_Out_ PDEVICE_DESCRIPTION DeviceDescription);

private:
    PPORTWAVERT m_pPort;
};
