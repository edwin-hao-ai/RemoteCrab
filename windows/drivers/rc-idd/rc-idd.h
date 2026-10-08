/*++
    RemoteCrab indirect display driver (rc-idd).

    An IddCx (Indirect Display Driver Class eXtension) UMDF driver that turns
    the iPhone into a real second monitor on Windows. It is the one piece of
    "Extended Display" that cannot be done in user mode: Windows has no
    equivalent of macOS's private `CGVirtualDisplay`, so a real extra screen
    needs a driver. Everything on the receiver side is in `rc-vdisplay`.

    Shape, learned from Microsoft's IddSampleDriver
    (video/IndirectDisplay/IddSampleDriver in Windows-driver-samples):

      * one adapter, created at D0 entry;
      * one monitor, created on demand by the control pipe (so a receiver with
        no active session leaves no phantom screen in the user's display
        settings);
      * the composed desktop frames arrive on the IddCx swap-chain; the
        swap-chain thread copies each one into `vdisplay-ring.bin`, the same
        double-buffered BGRA ring the receiver reads (`rc-vdisplay`);
      * a control pipe `\\.\pipe\RemoteCrabVDisplay` answers PING / MONITOR so
        the receiver can probe liveness and ask for a monitor.

    See README.md next to this file for the build, sign and install steps.
--*/

#pragma once

#define NOMINMAX
#include <windows.h>
#include <bugcodes.h>
#include <wudfwdm.h>
#include <wdf.h>
#include <iddcx.h>

#include <dxgi1_5.h>
#include <d3d11_2.h>
#include <avrt.h>
#include <wrl.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace RemoteCrab
{
namespace IndirectDisplay
{
    using Microsoft::WRL::ComPtr;

    // -- Frame ring (must match `rc-vcam::shm` / `rc-vdisplay`) --------------
    // Little-endian, fixed:
    //   off  0  u32 magic 'RCMV'
    //   off  4  u32 version
    //   off  8  u32 width
    //   off 12  u32 height
    //   off 16  u32 fps
    //   off 20  u32 stride (= width*4)
    //   off 24  u64 frame_seq
    //   off 32  u64 write_idx (0 or 1)
    //   off 40  ..  reserved to 64
    //   off 64  buf0, then buf1 (stride*height bytes each, BGRA)
    constexpr UINT32 RING_MAGIC = 0x52434D56; // 'RCMV'
    constexpr UINT32 RING_VERSION = 1;
    constexpr size_t RING_HEADER = 64;

    /// Owns the file-backed mapping the receiver reads. Written from the
    /// swap-chain thread, so `Publish` is called with `&` and must be the only
    /// writer (it is: one swap-chain thread at a time).
    class RingWriter
    {
    public:
        ~RingWriter() { Close(); }

        /// Create/grow + map the ring for `width`x`height` BGRA at `fps`, and
        /// write the header. Safe to call again with the same size (reopens).
        HRESULT Open(UINT32 width, UINT32 height, UINT32 fps);
        void Close();
        bool IsOpen() const { return m_view != nullptr; }

        /// Copy one BGRA frame (exactly `stride*height` bytes) into the
        /// non-current buffer and publish it. Ignores a wrong-sized frame.
        void Publish(const BYTE* bgra, size_t bytes);

        UINT32 width() const { return m_width; }
        UINT32 height() const { return m_height; }

    private:
        HANDLE m_file = INVALID_HANDLE_VALUE;
        HANDLE m_mapping = nullptr;
        void* m_view = nullptr;
        UINT32 m_width = 0;
        UINT32 m_height = 0;
        UINT32 m_fps = 0;
        UINT64 m_seq = 0;
        UINT32 m_idx = 0;
    };

    /// A Direct3D device on the render adapter the OS chose for the monitor.
    struct Direct3DDevice
    {
        explicit Direct3DDevice(LUID adapterLuid) : AdapterLuid(adapterLuid) {}
        HRESULT Init();

        LUID AdapterLuid;
        ComPtr<IDXGIFactory5> DxgiFactory;
        ComPtr<IDXGIAdapter1> Adapter;
        ComPtr<ID3D11Device> Device;
        ComPtr<ID3D11DeviceContext> DeviceContext;
    };

    /// The swap-chain thread: acquires composed frames and hands each to the
    /// ring. One per assigned swap-chain.
    class SwapChainProcessor
    {
    public:
        SwapChainProcessor(IDDCX_SWAPCHAIN hSwapChain,
                           std::shared_ptr<Direct3DDevice> device,
                           HANDLE newFrameEvent,
                           std::shared_ptr<RingWriter> ring);
        ~SwapChainProcessor();

    private:
        static DWORD CALLBACK RunThread(LPVOID argument);
        void Run();
        void RunCore();

        IDDCX_SWAPCHAIN m_hSwapChain;
        std::shared_ptr<Direct3DDevice> m_Device;
        std::shared_ptr<RingWriter> m_Ring;
        HANDLE m_hAvailableBufferEvent;
        Microsoft::WRL::Wrappers::Thread m_hThread;
        Microsoft::WRL::Wrappers::Event m_hTerminateEvent;
    };

    class IndirectMonitorContext;

    /// Per-device state: the adapter, the (optional) monitor, the ring, and
    /// the control pipe.
    class IndirectDeviceContext
    {
    public:
        explicit IndirectDeviceContext(WDFDEVICE wdfDevice);
        ~IndirectDeviceContext();

        void InitAdapter();
        void FinishInit();

        // Called from the control thread.
        HRESULT CreateMonitor(UINT32 width, UINT32 height);
        void DestroyMonitor();
        UINT32 RequestedWidth() const { return m_requestedWidth; }
        UINT32 RequestedHeight() const { return m_requestedHeight; }

    private:
        void StartControlPipe();
        void StopControlPipe();
        static DWORD CALLBACK ControlThread(LPVOID argument);
        void RunControlPipe();
        std::string HandleCommand(const std::string& line);

        WDFDEVICE m_WdfDevice;
        IDDCX_ADAPTER m_Adapter = nullptr;
        IDDCX_MONITOR m_Monitor = nullptr;
        std::shared_ptr<RingWriter> m_Ring;

        std::atomic<UINT32> m_requestedWidth{1920};
        std::atomic<UINT32> m_requestedHeight{1200};

        HANDLE m_hControlStop = nullptr;
        HANDLE m_hControlThread = nullptr;
        std::mutex m_monitorMutex;
    };

    class IndirectMonitorContext
    {
    public:
        explicit IndirectMonitorContext(IDDCX_MONITOR monitor) : m_Monitor(monitor) {}
        ~IndirectMonitorContext();

        /// The ring this monitor's frames are published into. Set once at
        /// monitor creation; used by the swap-chain thread.
        void SetRing(std::shared_ptr<RingWriter> ring) { m_Ring = std::move(ring); }

        /// The mode this monitor was created for. Read by the mode callbacks,
        /// which have only the monitor object to reach state through.
        void SetSize(UINT32 width, UINT32 height) { m_width = width; m_height = height; }
        UINT32 width() const { return m_width; }
        UINT32 height() const { return m_height; }

        void AssignSwapChain(IDDCX_SWAPCHAIN swapChain, LUID renderAdapter,
                             HANDLE newFrameEvent);
        void UnassignSwapChain();

    private:
        IDDCX_MONITOR m_Monitor;
        std::shared_ptr<RingWriter> m_Ring;
        std::unique_ptr<SwapChainProcessor> m_ProcessingThread;
        UINT32 m_width = 1920;
        UINT32 m_height = 1200;
    };
}
}
