/*++
    RemoteCrab indirect display driver (rc-idd) — implementation.

    Adapted from Microsoft's IddSampleDriver (Windows-driver-samples,
    video/IndirectDisplay/IddSampleDriver, MIT). The IddCx plumbing
    (DriverEntry, device add, adapter init, DDI callbacks) follows the sample;
    the RemoteCrab-specific parts are the frame ring and the control pipe.
--*/

#include "rc-idd.h"

#include <algorithm>
#include <cstdio>
#include <cstring>

using namespace RemoteCrab::IndirectDisplay;
using Microsoft::WRL::ComPtr;

// WDF context wrappers. Declared before any use, and registered with the
// context-type macro so `WdfObjectGet_*` exists. `Cleanup` is invoked from the
// device's `EvtCleanupCallback`.
struct IndirectDeviceContextWrapper
{
    IndirectDeviceContext* pContext = nullptr;
    void Cleanup()
    {
        delete pContext;
        pContext = nullptr;
    }
};

struct IndirectMonitorContextWrapper
{
    IndirectMonitorContext* pContext = nullptr;
    void Cleanup()
    {
        delete pContext;
        pContext = nullptr;
    }
};

WDF_DECLARE_CONTEXT_TYPE(IndirectDeviceContextWrapper);
WDF_DECLARE_CONTEXT_TYPE(IndirectMonitorContextWrapper);


#pragma region RingWriter

// %ProgramData%\RemoteCrab\vdisplay-ring.bin — the same directory and naming
// the receiver's `rc-vdisplay` opens. `ProgramData` is machine-wide and
// readable across sessions, which is why both ends use it.
static std::wstring RingPath()
{
    wchar_t buffer[MAX_PATH] = {};
    DWORD n = GetEnvironmentVariableW(L"ProgramData", buffer, MAX_PATH);
    std::wstring dir = (n > 0 && n < MAX_PATH) ? std::wstring(buffer, n) : L"C:\\ProgramData";
    dir += L"\\RemoteCrab";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\vdisplay-ring.bin";
}

// A NULL DACL: full access to everyone, so the user-session receiver can read
// the ring the driver (in WUDFHost) writes. Same trade-off the virtual camera
// makes; the file holds only screen pixels that the phone is already being
// sent, and the ring is not reachable over the network.
static void InitNullDacl(SECURITY_DESCRIPTOR& sd)
{
    InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION);
    SetSecurityDescriptorDacl(&sd, TRUE, nullptr, FALSE);
}

static void WriteRingHeader(void* view, UINT32 width, UINT32 height, UINT32 fps,
                            UINT64 seq, UINT32 idx)
{
    BYTE* base = static_cast<BYTE*>(view);
    auto put32 = [base](size_t off, UINT32 v) { memcpy(base + off, &v, sizeof(v)); };
    auto put64 = [base](size_t off, UINT64 v) { memcpy(base + off, &v, sizeof(v)); };
    put32(0, RING_MAGIC);
    put32(4, RING_VERSION);
    put32(8, width);
    put32(12, height);
    put32(16, fps);
    put32(20, width * 4);
    put64(24, seq);
    put64(32, static_cast<UINT64>(idx));
}

HRESULT RingWriter::Open(UINT32 width, UINT32 height, UINT32 fps)
{
    Close();
    if (width == 0 || height == 0)
    {
        return E_INVALIDARG;
    }
    const size_t frameBytes = static_cast<size_t>(width) * 4 * height;
    const size_t size = RING_HEADER + frameBytes * 2;

    std::wstring path = RingPath();

    SECURITY_DESCRIPTOR sd;
    InitNullDacl(sd);
    SECURITY_ATTRIBUTES sa = {};
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = &sd;
    sa.bInheritHandle = FALSE;

    m_file = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
                         FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
    if (m_file == INVALID_HANDLE_VALUE)
    {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    // Grow, never truncate: a receiver may hold the section open across a
    // driver restart, and CREATE_ALWAYS on a mapped file fails.
    LARGE_INTEGER current = {};
    if (GetFileSizeEx(m_file, &current) && current.QuadPart < static_cast<LONGLONG>(size))
    {
        LARGE_INTEGER end = {};
        end.QuadPart = static_cast<LONGLONG>(size);
        SetFilePointerEx(m_file, end, nullptr, FILE_BEGIN);
        SetEndOfFile(m_file);
    }

    m_mapping = CreateFileMappingW(m_file, &sa, PAGE_READWRITE, 0,
                                   static_cast<DWORD>(size), nullptr);
    if (m_mapping == nullptr)
    {
        HRESULT hr = HRESULT_FROM_WIN32(GetLastError());
        Close();
        return hr;
    }
    m_view = MapViewOfFile(m_mapping, FILE_MAP_ALL_ACCESS, 0, 0, size);
    if (m_view == nullptr)
    {
        HRESULT hr = HRESULT_FROM_WIN32(GetLastError());
        Close();
        return hr;
    }

    m_width = width;
    m_height = height;
    m_fps = fps;
    m_seq = 0;
    m_idx = 0;
    WriteRingHeader(m_view, width, height, fps, 0, 0);
    return S_OK;
}

void RingWriter::Close()
{
    if (m_view)
    {
        UnmapViewOfFile(m_view);
        m_view = nullptr;
    }
    if (m_mapping)
    {
        CloseHandle(m_mapping);
        m_mapping = nullptr;
    }
    if (m_file != INVALID_HANDLE_VALUE)
    {
        CloseHandle(m_file);
        m_file = INVALID_HANDLE_VALUE;
    }
}

void RingWriter::Publish(const BYTE* bgra, size_t bytes)
{
    if (!m_view || bgra == nullptr)
    {
        return;
    }
    const size_t frameBytes = static_cast<size_t>(m_width) * 4 * m_height;
    if (bytes != frameBytes)
    {
        return;
    }
    BYTE* base = static_cast<BYTE*>(m_view);
    const UINT32 next = m_idx ^ 1;
    BYTE* dst = base + RING_HEADER + frameBytes * next;
    memcpy(dst, bgra, frameBytes);
    m_seq += 1;
    m_idx = next;
    // The counter + index flip are the reader's whole synchronisation.
    WriteRingHeader(m_view, m_width, m_height, m_fps, m_seq, m_idx);
}

#pragma endregion

#pragma region Direct3DDevice

HRESULT Direct3DDevice::Init()
{
    HRESULT hr = CreateDXGIFactory2(0, IID_PPV_ARGS(&DxgiFactory));
    if (FAILED(hr))
    {
        return hr;
    }
    hr = DxgiFactory->EnumAdapterByLuid(AdapterLuid, IID_PPV_ARGS(&Adapter));
    if (FAILED(hr))
    {
        return hr;
    }
    // BGRA support is required: the composed desktop is BGRA.
    hr = D3D11CreateDevice(Adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                           D3D11_SDK_VERSION, &Device, nullptr, &DeviceContext);
    return hr;
}

#pragma endregion

#pragma region SwapChainProcessor

SwapChainProcessor::SwapChainProcessor(IDDCX_SWAPCHAIN hSwapChain,
                                       std::shared_ptr<Direct3DDevice> device,
                                       HANDLE newFrameEvent,
                                       std::shared_ptr<RingWriter> ring)
    : m_hSwapChain(hSwapChain), m_Device(std::move(device)), m_Ring(std::move(ring)),
      m_hAvailableBufferEvent(newFrameEvent)
{
    m_hTerminateEvent.Attach(CreateEvent(nullptr, FALSE, FALSE, nullptr));
    m_hThread = CreateThread(nullptr, 0, RunThread, this, 0, nullptr);
}

SwapChainProcessor::~SwapChainProcessor()
{
    SetEvent(m_hTerminateEvent.Get());
    if (m_hThread)
    {
        WaitForSingleObject(m_hThread, INFINITE);
        CloseHandle(m_hThread);
        m_hThread = nullptr;
    }
}

DWORD CALLBACK SwapChainProcessor::RunThread(LPVOID argument)
{
    reinterpret_cast<SwapChainProcessor*>(argument)->Run();
    return 0;
}

void SwapChainProcessor::Run()
{
    DWORD avTask = 0;
    HANDLE avTaskHandle = AvSetMmThreadCharacteristicsW(L"Distribution", &avTask);

    RunCore();

    // Deleting the swap-chain object kicks the OS to provide a new one if needed.
    WdfObjectDelete((WDFOBJECT)m_hSwapChain);
    m_hSwapChain = nullptr;

    if (avTaskHandle)
    {
        AvRevertMmThreadCharacteristics(avTaskHandle);
    }
}

void SwapChainProcessor::RunCore()
{
    ComPtr<IDXGIDevice> dxgiDevice;
    HRESULT hr = m_Device->Device.As(&dxgiDevice);
    if (FAILED(hr))
    {
        return;
    }

    IDARG_IN_SWAPCHAINSETDEVICE setDevice = {};
    setDevice.pDevice = dxgiDevice.Get();
    hr = IddCxSwapChainSetDevice(m_hSwapChain, &setDevice);
    if (FAILED(hr))
    {
        return;
    }

    // Staging texture reused across frames; recreated only when the surface
    // geometry changes.
    ComPtr<ID3D11Texture2D> staging;
    UINT32 stagingW = 0, stagingH = 0;

    for (;;)
    {
        ComPtr<IDXGIResource> acquiredBuffer;
        IDARG_OUT_RELEASEANDACQUIREBUFFER buffer = {};
        hr = IddCxSwapChainReleaseAndAcquireBuffer(m_hSwapChain, &buffer);

        if (hr == E_PENDING)
        {
            HANDLE waitHandles[] = { m_hAvailableBufferEvent, m_hTerminateEvent.Get() };
            DWORD wait = WaitForMultipleObjects(ARRAYSIZE(waitHandles), waitHandles, FALSE, 16);
            if (wait == WAIT_OBJECT_0 || wait == WAIT_TIMEOUT)
            {
                continue;
            }
            break; // terminate or unexpected
        }
        else if (SUCCEEDED(hr))
        {
            acquiredBuffer.Attach(buffer.MetaData.pSurface);

            ComPtr<ID3D11Texture2D> surface;
            if (acquiredBuffer && SUCCEEDED(acquiredBuffer.As(&surface)) && m_Ring && m_Ring->IsOpen())
            {
                D3D11_TEXTURE2D_DESC desc = {};
                surface->GetDesc(&desc);

                if (!staging || stagingW != desc.Width || stagingH != desc.Height)
                {
                    D3D11_TEXTURE2D_DESC sdesc = desc;
                    sdesc.Usage = D3D11_USAGE_STAGING;
                    sdesc.BindFlags = 0;
                    sdesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                    sdesc.MiscFlags = 0;
                    sdesc.ArraySize = 1;
                    sdesc.MipLevels = 1;
                    staging.Reset();
                    if (FAILED(m_Device->Device->CreateTexture2D(&sdesc, nullptr, &staging)))
                    {
                        staging = nullptr;
                    }
                    stagingW = desc.Width;
                    stagingH = desc.Height;
                }

                if (staging)
                {
                    m_Device->DeviceContext->CopyResource(staging.Get(), surface.Get());
                    D3D11_MAPPED_SUBRESOURCE map = {};
                    if (SUCCEEDED(m_Device->DeviceContext->Map(staging.Get(), 0,
                                                               D3D11_MAP_READ, 0, &map)))
                    {
                        const UINT32 w = m_Ring->width();
                        const UINT32 h = m_Ring->height();
                        if (desc.Width == w && desc.Height == h)
                        {
                            // Row-by-row: the mapped pitch is not necessarily
                            // width*4, and the ring requires a tight stride.
                            std::vector<BYTE> tight(static_cast<size_t>(w) * 4 * h);
                            const BYTE* src = static_cast<const BYTE*>(map.pData);
                            for (UINT32 y = 0; y < h; ++y)
                            {
                                memcpy(tight.data() + static_cast<size_t>(y) * w * 4,
                                       src + static_cast<size_t>(y) * map.RowPitch,
                                       static_cast<size_t>(w) * 4);
                            }
                            m_Ring->Publish(tight.data(), tight.size());
                        }
                        m_Device->DeviceContext->Unmap(staging.Get(), 0);
                    }
                }
            }

            acquiredBuffer.Reset();
            hr = IddCxSwapChainFinishedProcessingFrame(m_hSwapChain);
            if (FAILED(hr))
            {
                break;
            }
        }
        else
        {
            break; // swap-chain abandoned
        }
    }
}

#pragma endregion

#pragma region IndirectMonitorContext

IndirectMonitorContext::~IndirectMonitorContext()
{
    m_ProcessingThread.reset();
}

void IndirectMonitorContext::AssignSwapChain(IDDCX_SWAPCHAIN swapChain,
                                             LUID renderAdapter, HANDLE newFrameEvent)
{
    m_ProcessingThread.reset();
    auto device = std::make_shared<Direct3DDevice>(renderAdapter);
    if (FAILED(device->Init()))
    {
        // Delete the swap-chain so the OS generates a new one and retries.
        WdfObjectDelete(swapChain);
    }
    else
    {
        m_ProcessingThread.reset(
            new SwapChainProcessor(swapChain, device, newFrameEvent, m_Ring));
    }
}

void IndirectMonitorContext::UnassignSwapChain()
{
    m_ProcessingThread.reset();
}

#pragma endregion

#pragma region IndirectDeviceContext

// The pipe the receiver probes and commands. Matches `rc-vdisplay::PIPE_NAME`.
static const wchar_t* kPipeName = L"\\\\.\\pipe\\RemoteCrabVDisplay";

IndirectDeviceContext::IndirectDeviceContext(_In_ WDFDEVICE wdfDevice)
    : m_WdfDevice(wdfDevice)
{
    m_hControlStop = CreateEvent(nullptr, TRUE, FALSE, nullptr);
}

IndirectDeviceContext::~IndirectDeviceContext()
{
    StopControlPipe();
    m_Ring.reset();
}

void IndirectDeviceContext::InitAdapter()
{
    IDDCX_ADAPTER_CAPS adapterCaps = {};
    adapterCaps.Size = sizeof(adapterCaps);
    adapterCaps.MaxMonitorsSupported = 1;
    adapterCaps.EndPointDiagnostics.Size = sizeof(adapterCaps.EndPointDiagnostics);
    adapterCaps.EndPointDiagnostics.GammaSupport = IDDCX_FEATURE_IMPLEMENTATION_NONE;
    adapterCaps.EndPointDiagnostics.TransmissionType = IDDCX_TRANSMISSION_TYPE_WIRED_OTHER;
    adapterCaps.EndPointDiagnostics.pEndPointFriendlyName = L"RemoteCrab Display";
    adapterCaps.EndPointDiagnostics.pEndPointManufacturerName = L"RemoteCrab";
    adapterCaps.EndPointDiagnostics.pEndPointModelName = L"RemoteCrab Display";

    IDDCX_ENDPOINT_VERSION version = {};
    version.Size = sizeof(version);
    version.MajorVer = 1;
    adapterCaps.EndPointDiagnostics.pFirmwareVersion = &version;
    adapterCaps.EndPointDiagnostics.pHardwareVersion = &version;

    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, IndirectDeviceContextWrapper);

    IDARG_IN_ADAPTER_INIT adapterInit = {};
    adapterInit.WdfDevice = m_WdfDevice;
    adapterInit.pCaps = &adapterCaps;
    adapterInit.ObjectAttributes = &attr;

    IDARG_OUT_ADAPTER_INIT adapterInitOut = {};
    NTSTATUS status = IddCxAdapterInitAsync(&adapterInit, &adapterInitOut);
    if (NT_SUCCESS(status))
    {
        m_Adapter = adapterInitOut.AdapterObject;
        auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(m_Adapter);
        wrapper->pContext = this;
    }
}

void IndirectDeviceContext::FinishInit()
{
    // The adapter is ready; start answering the receiver.
    StartControlPipe();
}

HRESULT IndirectDeviceContext::CreateMonitor(UINT32 width, UINT32 height)
{
    std::lock_guard<std::mutex> lock(m_monitorMutex);
    if (m_Adapter == nullptr)
    {
        return E_FAIL;
    }
    if (width < 16 || height < 16)
    {
        return E_INVALIDARG;
    }

    // Replace any existing monitor so a size change takes effect.
    if (m_Monitor)
    {
        IddCxMonitorDeparture(m_Monitor);
        m_Monitor = nullptr;
    }

    m_requestedWidth = width;
    m_requestedHeight = height;

    if (!m_Ring)
    {
        m_Ring = std::make_shared<RingWriter>();
    }
    HRESULT hr = m_Ring->Open(width, height, 60);
    if (FAILED(hr))
    {
        return hr;
    }

    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, IndirectMonitorContextWrapper);

    IDDCX_MONITOR_INFO info = {};
    info.Size = sizeof(info);
    info.MonitorType = DISPLAYCONFIG_OUTPUT_TECHNOLOGY_HDMI;
    info.ConnectorIndex = 0;
    info.MonitorDescription.Size = sizeof(info.MonitorDescription);
    info.MonitorDescription.Type = IDDCX_MONITOR_DESCRIPTION_TYPE_EDID;
    // No EDID: the OS uses `EvtIddCxMonitorGetDefaultDescriptionModes`, which
    // reports exactly the size the receiver asked for.
    info.MonitorDescription.DataSize = 0;
    info.MonitorDescription.pData = nullptr;
    CoCreateGuid(&info.MonitorContainerId);

    IDARG_IN_MONITORCREATE create = {};
    create.ObjectAttributes = &attr;
    create.pMonitorInfo = &info;

    IDARG_OUT_MONITORCREATE createOut = {};
    NTSTATUS status = IddCxMonitorCreate(m_Adapter, &create, &createOut);
    if (!NT_SUCCESS(status))
    {
        return E_FAIL;
    }

    auto* wrapper = WdfObjectGet_IndirectMonitorContextWrapper(createOut.MonitorObject);
    wrapper->pContext = new IndirectMonitorContext(createOut.MonitorObject);
    wrapper->pContext->SetRing(m_Ring);
    wrapper->pContext->SetSize(width, height);

    IDARG_OUT_MONITORARRIVAL arrival = {};
    status = IddCxMonitorArrival(createOut.MonitorObject, &arrival);
    if (!NT_SUCCESS(status))
    {
        return E_FAIL;
    }

    m_Monitor = createOut.MonitorObject;
    return S_OK;
}

void IndirectDeviceContext::DestroyMonitor()
{
    std::lock_guard<std::mutex> lock(m_monitorMutex);
    if (m_Monitor)
    {
        IddCxMonitorDeparture(m_Monitor);
        m_Monitor = nullptr;
    }
}

void IndirectDeviceContext::StartControlPipe()
{
    if (m_hControlThread)
    {
        return;
    }
    ResetEvent(m_hControlStop);
    m_hControlThread = CreateThread(nullptr, 0, ControlThread, this, 0, nullptr);
}

void IndirectDeviceContext::StopControlPipe()
{
    if (!m_hControlThread)
    {
        return;
    }
    SetEvent(m_hControlStop);
    // Unblock `ConnectNamedPipe` by connecting to our own pipe once.
    HANDLE wake = CreateFileW(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, 0, nullptr);
    if (wake != INVALID_HANDLE_VALUE)
    {
        CloseHandle(wake);
    }
    WaitForSingleObject(m_hControlThread, 2000);
    CloseHandle(m_hControlThread);
    m_hControlThread = nullptr;
}

DWORD CALLBACK IndirectDeviceContext::ControlThread(LPVOID argument)
{
    reinterpret_cast<IndirectDeviceContext*>(argument)->RunControlPipe();
    return 0;
}

std::string IndirectDeviceContext::HandleCommand(const std::string& line)
{
    if (line == "PING")
    {
        return "PONG 1";
    }
    if (line == "MONITOR OFF")
    {
        DestroyMonitor();
        return "OK";
    }
    if (line.rfind("MONITOR ", 0) == 0)
    {
        unsigned w = 0, h = 0;
        if (sscanf_s(line.c_str() + 8, "%u %u", &w, &h) == 2)
        {
            HRESULT hr = CreateMonitor(w, h);
            return SUCCEEDED(hr) ? std::string("OK")
                                 : std::string("ERR monitor_create_failed");
        }
        return "ERR bad_monitor_command";
    }
    return "ERR unknown_command";
}

void IndirectDeviceContext::RunControlPipe()
{
    SECURITY_DESCRIPTOR sd;
    InitNullDacl(sd);
    SECURITY_ATTRIBUTES sa = {};
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = &sd;
    sa.bInheritHandle = FALSE;

    for (;;)
    {
        if (WaitForSingleObject(m_hControlStop, 0) == WAIT_OBJECT_0)
        {
            break;
        }
        HANDLE pipe = CreateNamedPipeW(kPipeName, PIPE_ACCESS_DUPLEX,
                                       PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                                       1, 4096, 4096, 0, &sa);
        if (pipe == INVALID_HANDLE_VALUE)
        {
            break;
        }
        BOOL connected = ConnectNamedPipe(pipe, nullptr)
                             ? TRUE
                             : (GetLastError() == ERROR_PIPE_CONNECTED);
        if (connected)
        {
            char buffer[256] = {};
            DWORD read = 0;
            if (ReadFile(pipe, buffer, sizeof(buffer) - 1, &read, nullptr) && read > 0)
            {
                std::string line(buffer, read);
                while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
                {
                    line.pop_back();
                }
                std::string reply = HandleCommand(line) + "\n";
                DWORD written = 0;
                WriteFile(pipe, reply.data(), static_cast<DWORD>(reply.size()), &written, nullptr);
                FlushFileBuffers(pipe);
            }
            DisconnectNamedPipe(pipe);
        }
        CloseHandle(pipe);
    }
}

#pragma endregion

#pragma region WDF entry + device

extern "C" DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD RcIddDeviceAdd;
EVT_WDF_DEVICE_D0_ENTRY RcIddDeviceD0Entry;
EVT_IDD_CX_ADAPTER_INIT_FINISHED RcIddAdapterInitFinished;
EVT_IDD_CX_ADAPTER_COMMIT_MODES RcIddAdapterCommitModes;
EVT_IDD_CX_MONITOR_GET_DEFAULT_DESCRIPTION_MODES RcIddMonitorGetDefaultModes;
EVT_IDD_CX_MONITOR_QUERY_TARGET_MODES RcIddMonitorQueryModes;
EVT_IDD_CX_MONITOR_ASSIGN_SWAPCHAIN RcIddMonitorAssignSwapChain;
EVT_IDD_CX_MONITOR_UNASSIGN_SWAPCHAIN RcIddMonitorUnassignSwapChain;

extern "C" BOOL WINAPI DllMain(_In_ HINSTANCE, _In_ UINT, _In_opt_ LPVOID)
{
    return TRUE;
}

extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT driverObject, PUNICODE_STRING registryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, RcIddDeviceAdd);

    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);

    return WdfDriverCreate(driverObject, registryPath, &attributes, &config, WDF_NO_HANDLE);
}

NTSTATUS RcIddDeviceAdd(WDFDRIVER, PWDFDEVICE_INIT deviceInit)
{
    WDF_PNPPOWER_EVENT_CALLBACKS pnpPower;
    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnpPower);
    pnpPower.EvtDeviceD0Entry = RcIddDeviceD0Entry;
    WdfDeviceInitSetPnpPowerEventCallbacks(deviceInit, &pnpPower);

    IDD_CX_CLIENT_CONFIG iddConfig;
    IDD_CX_CLIENT_CONFIG_INIT(&iddConfig);
    iddConfig.EvtIddCxAdapterInitFinished = RcIddAdapterInitFinished;
    iddConfig.EvtIddCxAdapterCommitModes = RcIddAdapterCommitModes;
    iddConfig.EvtIddCxMonitorGetDefaultDescriptionModes = RcIddMonitorGetDefaultModes;
    iddConfig.EvtIddCxMonitorQueryTargetModes = RcIddMonitorQueryModes;
    iddConfig.EvtIddCxMonitorAssignSwapChain = RcIddMonitorAssignSwapChain;
    iddConfig.EvtIddCxMonitorUnassignSwapChain = RcIddMonitorUnassignSwapChain;

    NTSTATUS status = IddCxDeviceInitConfig(deviceInit, &iddConfig);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    WDF_OBJECT_ATTRIBUTES attr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attr, IndirectDeviceContextWrapper);
    attr.EvtCleanupCallback = [](WDFOBJECT object)
    {
        auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(object);
        if (wrapper)
        {
            wrapper->Cleanup();
        }
    };

    WDFDEVICE device = nullptr;
    status = WdfDeviceCreate(&deviceInit, &attr, &device);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    status = IddCxDeviceInitialize(device);
    if (!NT_SUCCESS(status))
    {
        return status;
    }

    auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(device);
    wrapper->pContext = new IndirectDeviceContext(device);
    return STATUS_SUCCESS;
}

NTSTATUS RcIddDeviceD0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE)
{
    auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(device);
    wrapper->pContext->InitAdapter();
    return STATUS_SUCCESS;
}

#pragma endregion

#pragma region helpers + DDI callbacks

static void FillSignalInfo(DISPLAYCONFIG_VIDEO_SIGNAL_INFO& mode, DWORD width,
                           DWORD height, DWORD vSync, bool monitorMode)
{
    mode.totalSize.cx = mode.activeSize.cx = width;
    mode.totalSize.cy = mode.activeSize.cy = height;
    mode.AdditionalSignalInfo.vSyncFreqDivider = monitorMode ? 0 : 1;
    mode.AdditionalSignalInfo.videoStandard = 255;
    mode.vSyncFreq.Numerator = vSync;
    mode.vSyncFreq.Denominator = 1;
    mode.hSyncFreq.Numerator = vSync * height;
    mode.hSyncFreq.Denominator = 1;
    mode.scanLineOrdering = DISPLAYCONFIG_SCANLINE_ORDERING_PROGRESSIVE;
    mode.pixelRate = static_cast<UINT64>(vSync) * width * height;
}

static IDDCX_MONITOR_MODE CreateMonitorMode(DWORD width, DWORD height, DWORD vSync)
{
    IDDCX_MONITOR_MODE mode = {};
    mode.Size = sizeof(mode);
    mode.Origin = IDDCX_MONITOR_MODE_ORIGIN_DRIVER;
    FillSignalInfo(mode.MonitorVideoSignalInfo, width, height, vSync, true);
    return mode;
}

static IDDCX_TARGET_MODE CreateTargetMode(DWORD width, DWORD height, DWORD vSync)
{
    IDDCX_TARGET_MODE mode = {};
    mode.Size = sizeof(mode);
    FillSignalInfo(mode.TargetVideoSignalInfo.targetVideoSignalInfo, width, height, vSync, false);
    return mode;
}

NTSTATUS RcIddAdapterInitFinished(IDDCX_ADAPTER adapterObject,
                                  const IDARG_IN_ADAPTER_INIT_FINISHED* inArgs)
{
    auto* wrapper = WdfObjectGet_IndirectDeviceContextWrapper(adapterObject);
    if (NT_SUCCESS(inArgs->AdapterInitStatus) && wrapper && wrapper->pContext)
    {
        wrapper->pContext->FinishInit();
    }
    return STATUS_SUCCESS;
}

NTSTATUS RcIddAdapterCommitModes(IDDCX_ADAPTER, const IDARG_IN_COMMITMODES*)
{
    // Nothing to reconfigure: IddCx owns the swap-chain, and our ring is fed
    // from it regardless of which path is active.
    return STATUS_SUCCESS;
}

NTSTATUS RcIddMonitorGetDefaultModes(IDDCX_MONITOR monitorObject,
                                     const IDARG_IN_GETDEFAULTDESCRIPTIONMODES* inArgs,
                                     IDARG_OUT_GETDEFAULTDESCRIPTIONMODES* outArgs)
{
    auto* wrapper = WdfObjectGet_IndirectMonitorContextWrapper(monitorObject);
    DWORD width = wrapper && wrapper->pContext ? wrapper->pContext->width() : 1920;
    DWORD height = wrapper && wrapper->pContext ? wrapper->pContext->height() : 1200;

    if (inArgs->DefaultMonitorModeBufferInputCount == 0)
    {
        outArgs->DefaultMonitorModeBufferOutputCount = 1;
        return STATUS_SUCCESS;
    }
    inArgs->pDefaultMonitorModes[0] = CreateMonitorMode(width, height, 60);
    outArgs->DefaultMonitorModeBufferOutputCount = 1;
    outArgs->PreferredMonitorModeIdx = 0;
    return STATUS_SUCCESS;
}

NTSTATUS RcIddMonitorQueryModes(IDDCX_MONITOR monitorObject,
                                const IDARG_IN_QUERYTARGETMODES* inArgs,
                                IDARG_OUT_QUERYTARGETMODES* outArgs)
{
    auto* wrapper = WdfObjectGet_IndirectMonitorContextWrapper(monitorObject);
    DWORD width = wrapper && wrapper->pContext ? wrapper->pContext->width() : 1920;
    DWORD height = wrapper && wrapper->pContext ? wrapper->pContext->height() : 1200;

    // The OS reports the intersection of monitor modes and target modes, so
    // the requested size must appear here too. A couple of standard modes keep
    // the list non-degenerate for the display control panel.
    std::vector<IDDCX_TARGET_MODE> modes;
    modes.push_back(CreateTargetMode(width, height, 60));
    modes.push_back(CreateTargetMode(1920, 1080, 60));
    modes.push_back(CreateTargetMode(1280, 720, 60));

    outArgs->TargetModeBufferOutputCount = static_cast<UINT>(modes.size());
    if (inArgs->TargetModeBufferInputCount >= modes.size())
    {
        std::copy(modes.begin(), modes.end(), inArgs->pTargetModes);
    }
    return STATUS_SUCCESS;
}

NTSTATUS RcIddMonitorAssignSwapChain(IDDCX_MONITOR monitorObject,
                                     const IDARG_IN_SETSWAPCHAIN* inArgs)
{
    auto* wrapper = WdfObjectGet_IndirectMonitorContextWrapper(monitorObject);
    wrapper->pContext->AssignSwapChain(inArgs->hSwapChain, inArgs->RenderAdapterLuid,
                                       inArgs->hNextSurfaceAvailable);
    return STATUS_SUCCESS;
}

NTSTATUS RcIddMonitorUnassignSwapChain(IDDCX_MONITOR monitorObject)
{
    auto* wrapper = WdfObjectGet_IndirectMonitorContextWrapper(monitorObject);
    wrapper->pContext->UnassignSwapChain();
    return STATUS_SUCCESS;
}

#pragma endregion
