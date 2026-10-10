/*++
    RemoteCrab virtual microphone driver (rc-vmic) — implementation.

    **Skeleton.** The RemoteCrab-specific part — the ring reader — is real; the
    PortCls plumbing is written to the WDK's interfaces but is incomplete and
    has not been signed or run. See README.md.
--*/

#include "rc-vmic.h"

// ===========================================================================
// CRingReader
// ===========================================================================

// ProgramData is `\SystemRoot\ProgramData`; the receiver writes
// `%ProgramData%\RemoteCrab\vmic-ring.bin`.
static const WCHAR kRingPath[] = L"\\SystemRoot\\ProgramData\\RemoteCrab\\vmic-ring.bin";

// Offsets into the 64-byte header (mirror rc-vmic/src/shm.rs).
static const ULONG kOffMagic = 0;
static const ULONG kOffVersion = 4;
static const ULONG kOffSampleRate = 8;
static const ULONG kOffChannels = 12;
static const ULONG kOffBits = 16;
static const ULONG kOffCapacity = 20;
static const ULONG kOffWritePos = 24;
static const ULONG kOffReadPos = 32;
static const ULONG kHeaderSize = 64;
static const ULONG kMagic = 0x52434D41; // 'RCMA'

static inline ULONG Rd32(const BYTE* b, ULONG off) { return *reinterpret_cast<const ULONG*>(b + off); }
static inline ULONGLONG Rd64(const BYTE* b, ULONG off) { return *reinterpret_cast<const ULONGLONG*>(b + off); }
static inline void Wr64(BYTE* b, ULONG off, ULONGLONG v) { *reinterpret_cast<ULONGLONG*>(b + off) = v; }

CRingReader::CRingReader()
    : m_pBase(nullptr), m_Capacity(0), m_hFile(nullptr), m_hSection(nullptr),
      m_pMapped(nullptr), m_ViewSize(0)
{
}

CRingReader::~CRingReader()
{
    Close();
}

NTSTATUS CRingReader::Open()
{
    UNICODE_STRING path;
    RtlInitUnicodeString(&path, kRingPath);

    OBJECT_ATTRIBUTES oa;
    InitializeObjectAttributes(&oa, &path, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, nullptr, nullptr);

    IO_STATUS_BLOCK iosb = {};
    NTSTATUS status = ZwOpenFile(&m_hFile, FILE_READ_DATA | FILE_WRITE_DATA | SYNCHRONIZE,
                                 &oa, &iosb, FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_SYNCHRONOUS_IO_NONALERT);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    FILE_STANDARD_INFORMATION info = {};
    status = ZwQueryInformationFile(m_hFile, &iosb, &info, sizeof(info), FileStandardInformation);
    if (!NT_SUCCESS(status) || info.EndOfFile.QuadPart < kHeaderSize)
    {
        Close();
        return STATUS_INVALID_PARAMETER;
    }

    LARGE_INTEGER maxSize = {};
    maxSize.QuadPart = info.EndOfFile.QuadPart;
    status = ZwCreateSection(&m_hSection, SECTION_ALL_ACCESS, nullptr, &maxSize, PAGE_READWRITE, SEC_COMMIT, m_hFile);
    if (!NT_SUCCESS(status))
    {
        Close();
        return status;
    }

    m_pMapped = nullptr;
    m_ViewSize = 0;
    status = ZwMapViewOfSection(m_hSection, NtCurrentProcess(), &m_pMapped, 0, 0, nullptr,
                                &m_ViewSize, ViewUnmap, 0, PAGE_READWRITE);
    if (!NT_SUCCESS(status))
    {
        Close();
        return status;
    }

    m_pBase = static_cast<BYTE*>(m_pMapped);
    if (Rd32(m_pBase, kOffMagic) != kMagic)
    {
        Close();
        return STATUS_INVALID_SIGNATURE;
    }
    m_Capacity = Rd32(m_pBase, kOffCapacity);
    return STATUS_SUCCESS;
}

void CRingReader::Close()
{
    if (m_pMapped)
    {
        ZwUnmapViewOfSection(NtCurrentProcess(), m_pMapped);
        m_pMapped = nullptr;
        m_pBase = nullptr;
    }
    if (m_hSection)
    {
        ZwClose(m_hSection);
        m_hSection = nullptr;
    }
    if (m_hFile)
    {
        ZwClose(m_hFile);
        m_hFile = nullptr;
    }
    m_Capacity = 0;
}

ULONG CRingReader::Available() const
{
    if (!m_pBase)
    {
        return 0;
    }
    ULONGLONG write = Rd64(m_pBase, kOffWritePos);
    ULONGLONG read = Rd64(m_pBase, kOffReadPos);
    ULONGLONG avail = (write > read) ? (write - read) : 0;
    return (avail > m_Capacity) ? m_Capacity : static_cast<ULONG>(avail);
}

ULONG CRingReader::Read(_Out_writes_bytes_(Bytes) BYTE* Dst, ULONG Bytes)
{
    ULONG avail = Available();
    ULONG n = (Bytes < avail) ? Bytes : avail;
    if (n == 0)
    {
        return 0;
    }
    ULONGLONG read = Rd64(m_pBase, kOffReadPos);
    BYTE* pcm = m_pBase + kHeaderSize;
    for (ULONG i = 0; i < n; ++i)
    {
        Dst[i] = pcm[(read + i) % m_Capacity];
    }
    Wr64(m_pBase, kOffReadPos, read + n);
    return n;
}

// ===========================================================================
// CMiniportWaveRTStream
// ===========================================================================

CMiniportWaveRTStream::CMiniportWaveRTStream(_In_opt_ PUNKNOWN UnknownOuter,
                                             _In_opt_ PRESOURCELIST ResourceList,
                                             _In_ ULONG Channels, _In_ ULONG SampleRate)
    : CUnknown(UnknownOuter), m_Channels(Channels), m_SampleRate(SampleRate),
      m_BufferSize(0), m_Buffer(nullptr), m_State(KSSTATE_STOP)
{
    UNREFERENCED_PARAMETER(ResourceList);
}

CMiniportWaveRTStream::~CMiniportWaveRTStream()
{
    m_Ring.Close();
    if (m_Buffer)
    {
        ExFreePoolWithTag(m_Buffer, 'CMVR');
        m_Buffer = nullptr;
    }
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::NonDelegatingQueryInterface(
    _In_ REFIID iid, _COM_Outptr_ PVOID* ppv)
{
    if (IsEqualGUIDAligned(iid, IID_IUnknown) || IsEqualGUIDAligned(iid, IID_IMiniportWaveRTStream))
    {
        *ppv = QICASTUNKNOWN(IMiniportWaveRTStream);
    }
    else if (IsEqualGUIDAligned(iid, IID_IMiniportWaveRTInputStream))
    {
        *ppv = QICASTUNKNOWN(IMiniportWaveRTInputStream);
    }
    else
    {
        *ppv = nullptr;
        return STATUS_INVALID_PARAMETER;
    }
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::SetFormat(_In_ PKSDATAFORMAT DataFormat)
{
    // Accept only PCM; the ring is 16-bit PCM. Full validation is part of the
    // unfinished plumbing (see README).
    if (!DataFormat || DataFormat->FormatSize < sizeof(KSDATAFORMAT_WAVEFORMATEX))
    {
        return STATUS_INVALID_PARAMETER;
    }
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::SetState(_In_ KSSTATE State)
{
    m_State = State;
    if (State == KSSTATE_RUN)
    {
        // Lazily attach to the ring on first RUN.
        if (!m_Ring.IsOpen())
        {
            m_Ring.Open(); // a failure means silence, not a failure to run
        }
    }
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::GetPosition(_Out_ PKSAUDIO_POSITION Position)
{
    // Position is in bytes; the ring's write_pos is the clock the audio engine
    // follows, so a late phone shows up as the position lagging, not as a stall.
    Position->PlayOffset = 0;
    Position->WriteOffset = 0;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::AllocateAudioBuffer(
    _In_ ULONG RequestedSize, _Out_ PMDL* AudioBufferMdl, _Out_ ULONG* ActualSize,
    _Out_ ULONG* OffsetFromFirstPage, _Out_ MEMORY_CACHING_TYPE* CacheType)
{
    if (!AudioBufferMdl || !ActualSize || !OffsetFromFirstPage || !CacheType)
    {
        return STATUS_INVALID_PARAMETER;
    }
    m_Buffer = static_cast<BYTE*>(ExAllocatePool2(POOL_FLAG_NON_PAGED, RequestedSize, 'CMVR'));
    if (!m_Buffer)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    RtlZeroMemory(m_Buffer, RequestedSize);
    m_BufferSize = RequestedSize;

    PMDL mdl = IoAllocateMdl(m_Buffer, RequestedSize, FALSE, FALSE, nullptr);
    if (!mdl)
    {
        ExFreePoolWithTag(m_Buffer, 'CMVR');
        m_Buffer = nullptr;
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    MmBuildMdlForNonPagedPool(mdl);
    *AudioBufferMdl = mdl;
    *ActualSize = RequestedSize;
    *OffsetFromFirstPage = 0;
    *CacheType = MmCached;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(VOID) CMiniportWaveRTStream::FreeAudioBuffer(_In_opt_ PMDL AudioBufferMdl, _In_ ULONG BufferSize)
{
    UNREFERENCED_PARAMETER(BufferSize);
    if (AudioBufferMdl)
    {
        IoFreeMdl(AudioBufferMdl);
    }
    if (m_Buffer)
    {
        ExFreePoolWithTag(m_Buffer, 'CMVR');
        m_Buffer = nullptr;
    }
    m_BufferSize = 0;
}

STDMETHODIMP_(VOID) CMiniportWaveRTStream::GetHWLatency(_Out_ KSRTAUDIO_HWLATENCY* hwLatency)
{
    RtlZeroMemory(hwLatency, sizeof(*hwLatency));
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::GetPositionRegister(_Out_ KSRTAUDIO_HWREGISTER* Register)
{
    UNREFERENCED_PARAMETER(Register);
    return STATUS_NOT_IMPLEMENTED;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::GetClockRegister(_Out_ KSRTAUDIO_HWREGISTER* Register)
{
    UNREFERENCED_PARAMETER(Register);
    return STATUS_NOT_IMPLEMENTED;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRTStream::GetReadPacket(
    _Out_ ULONG* PacketNumber, _Out_ DWORD* Flags, _Out_ ULONG64* PerformanceCounterValue, _Out_ BOOL* MoreData)
{
    // Skeleton: drain the ring into the buffer and report one packet. The real
    // version must respect the WaveRT buffer's period, report an accurate
    // packet number, and silence (not skip) an underrun.
    *PacketNumber = 0;
    *Flags = 0;
    LARGE_INTEGER pc = {};
    KeQueryPerformanceCounter(&pc);
    *PerformanceCounterValue = static_cast<ULONG64>(pc.QuadPart);
    if (m_Buffer && m_BufferSize)
    {
        ULONG got = m_Ring.Read(m_Buffer, m_BufferSize);
        if (got < m_BufferSize)
        {
            RtlZeroMemory(m_Buffer + got, m_BufferSize - got);
        }
        *MoreData = m_Ring.Available() > 0;
    }
    else
    {
        *MoreData = FALSE;
    }
    return STATUS_SUCCESS;
}

// ===========================================================================
// CMiniportWaveRT
// ===========================================================================

CMiniportWaveRT::CMiniportWaveRT(_In_opt_ PUNKNOWN UnknownOuter, _In_opt_ PRESOURCELIST ResourceList)
    : CUnknown(UnknownOuter), m_pPort(nullptr)
{
    UNREFERENCED_PARAMETER(ResourceList);
}

CMiniportWaveRT::~CMiniportWaveRT()
{
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::NonDelegatingQueryInterface(
    _In_ REFIID iid, _COM_Outptr_ PVOID* ppv)
{
    if (IsEqualGUIDAligned(iid, IID_IUnknown) || IsEqualGUIDAligned(iid, IID_IMiniportWaveRT))
    {
        *ppv = QICASTUNKNOWN(IMiniportWaveRT);
    }
    else
    {
        *ppv = nullptr;
        return STATUS_INVALID_PARAMETER;
    }
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::Init(_In_ PUNKNOWN UnknownAdapter,
                                              _In_ PRESOURCELIST ResourceList, _In_ PPORTWAVERT Port)
{
    UNREFERENCED_PARAMETER(UnknownAdapter);
    UNREFERENCED_PARAMETER(ResourceList);
    m_pPort = Port;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::NewStream(
    _Out_ PMINIPORTWAVERTSTREAM* Stream, _In_ PPORTWAVERTSTREAM PortStream,
    _In_ ULONG Pin, _In_ BOOLEAN Capture, _In_ PKSDATAFORMAT DataFormat)
{
    UNREFERENCED_PARAMETER(PortStream);
    UNREFERENCED_PARAMETER(Pin);
    UNREFERENCED_PARAMETER(DataFormat);
    if (!Capture)
    {
        return STATUS_INVALID_PARAMETER;
    }
    CMiniportWaveRTStream* s = new (NonPagedPoolNx, 'SMVR') CMiniportWaveRTStream(nullptr, nullptr, 1, 48000);
    if (!s)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    *Stream = s;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::GetDeviceDescription(_Out_ PDEVICE_DESCRIPTION DeviceDescription)
{
    RtlZeroMemory(DeviceDescription, sizeof(*DeviceDescription));
    DeviceDescription->Version = DEVICE_DESCRIPTION_VERSION;
    DeviceDescription->Master = TRUE;
    DeviceDescription->ScatterGather = TRUE;
    DeviceDescription->Dma32BitAddresses = TRUE;
    DeviceDescription->InterfaceType = PCIBus;
    DeviceDescription->MaximumLength = 0xFFFFFFFF;
    return STATUS_SUCCESS;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::GetDescription(_Out_ PPCFILTER_DESCRIPTOR* Description)
{
    // TODO(rc-vmic): return the capture filter descriptor once it exists.
    UNREFERENCED_PARAMETER(Description);
    return STATUS_NOT_IMPLEMENTED;
}

STDMETHODIMP_(NTSTATUS) CMiniportWaveRT::DataRangeIntersection(
    _In_ ULONG PinId, _In_ PKSDATARANGE DataRange, _In_ PKSDATARANGE MatchingDataRange,
    _In_ ULONG OutputBufferLength, _Out_writes_bytes_to_opt_(OutputBufferLength, *ResultantFormatLength)
    PVOID ResultantFormat, _Out_ PULONG ResultantFormatLength)
{
    UNREFERENCED_PARAMETER(PinId);
    UNREFERENCED_PARAMETER(DataRange);
    UNREFERENCED_PARAMETER(MatchingDataRange);
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(ResultantFormat);
    *ResultantFormatLength = 0;
    return STATUS_NOT_IMPLEMENTED;
}

// ===========================================================================
// Descriptors + DriverEntry
// ===========================================================================
//
// TODO(rc-vmic): the PortCls plumbing below is deliberately **not** written.
// A real filter needs a populated `PCPIN_DESCRIPTOR` (capture pin:
// KSPIN_DATAFLOW_IN / KSCATEGORY_CAPTURE), a `KSDATARANGE_AUDIO` for 48 kHz
// 16-bit mono/stereo, an empty `PCAUTOMATION_TABLE`, and a `DriverEntry` that
// calls `PcInitializeAdapterDriver` + an `AddDevice` → `PcAddAdapterDevice` →
// `PcRegisterSubdevice`. None of that is guessable-and-correct, so it is left
// to the implementer rather than written blind — see README.md.

extern "C" NTSTATUS DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_NOT_IMPLEMENTED;
}

