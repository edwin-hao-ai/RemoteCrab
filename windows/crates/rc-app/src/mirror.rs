//! App-window mirror (Windows): capture the frontmost (or pinned) window,
//! H.264-encode it, and stream it to the iPhone as `screenSps`/`screenPps`/
//! `screenVideo` + `screenInfo` (kinds `0x1A`–`0x1C`/`0x1F`).
//!
//! The capture/encode loop runs on a dedicated thread because `PrintWindow`
//! and OpenH264 are blocking and CPU-bound; input (`screenInput`) stays on
//! the async loop, which reads the target geometry from [`MirrorController`].
//!
//! The capture half is `cfg(windows)`. The controller, its geometry maths and
//! its tests are not, so a `#[cfg]` sprinkled through working Windows code is
//! not worth it — the module-level allow below keeps the non-Windows build
//! quiet without hiding anything on the platform that ships.
#![cfg_attr(not(windows), allow(dead_code))]

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
#[cfg(windows)]
use std::time::{Duration, Instant};

use rc_net::Session;
// Window capture is a Win32 API, so everything the capture loop needs is
// Windows-only. Gating the imports (rather than the whole module) is what lets
// the controller, its geometry maths and its tests build and run anywhere.
#[cfg(windows)]
use rc_protocol::{
    encode_screen_info, encode_screen_nal, NalFrame, NalKind, ScreenInfo, ScreenStatus,
};

#[cfg(windows)]
const FRAME_INTERVAL: Duration = Duration::from_millis(33); // ~30 fps
#[cfg(windows)]
const INFO_INTERVAL: Duration = Duration::from_millis(1000);
const DEFAULT_MAX_PIXEL: u32 = 1920;

#[derive(Default)]
struct Shared {
    running: bool,
    /// Pinned window id; `None` follows the frontmost window.
    desired: Option<String>,
    max_pixel: u32,
    /// Current target frame `(origin_x, origin_y, width, height)` in
    /// virtual-desktop pixels, for mapping `screenInput`.
    geometry: Option<(f64, f64, f64, f64)>,
    /// When true the source is the virtual display (an IddCx monitor) rather
    /// than a window. Chosen once per run — switching source restarts the
    /// capture thread, exactly like changing the requested size does.
    virtual_display: bool,
}

/// Lock that survives a poisoned mutex.
///
/// A panic elsewhere can never leave `Shared` half-written (it is three plain
/// fields plus an `Option`), so the data is still valid — but `lock().unwrap()`
/// would turn that unrelated panic into a second one, and in a tray app a panic
/// anywhere takes the whole process (notification area and all) with it. Recover
/// the guard instead of propagating.
fn lock(shared: &Mutex<Shared>) -> std::sync::MutexGuard<'_, Shared> {
    shared
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Owns the mirror capture thread. Cheap to keep for the app's lifetime.
pub struct MirrorController {
    session: Session,
    shared: Arc<Mutex<Shared>>,
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

/// Which pixels the capture thread streams.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Source {
    /// The frontmost (or pinned) window, via `PrintWindow`.
    Window,
    /// The IddCx virtual monitor, via its frame ring.
    VirtualDisplay,
}

impl MirrorController {
    pub fn new(session: Session) -> Self {
        Self {
            session,
            shared: Arc::new(Mutex::new(Shared {
                running: false,
                desired: None,
                max_pixel: DEFAULT_MAX_PIXEL,
                geometry: None,
                virtual_display: false,
            })),
            stop: Arc::new(AtomicBool::new(false)),
            handle: None,
        }
    }

    /// Start (or restart) streaming a window. `max_pixel` is the phone's
    /// long-edge cap.
    pub fn start(&mut self, max_pixel: Option<u32>) {
        let max_pixel = max_pixel.unwrap_or(DEFAULT_MAX_PIXEL).clamp(320, 4096);
        self.restart(Source::Window, max_pixel);
    }

    /// Stream the **virtual display** instead of a window — the phone becomes
    /// a real second monitor.
    ///
    /// `Err` when no IddCx driver is installed (so the caller can say why);
    /// otherwise the driver creates a monitor at `max_pixel × max_pixel*10/16`
    /// (the same 16:10 the Mac uses) and the capture thread reads its frames.
    pub fn extend(&mut self, max_pixel: Option<u32>) -> Result<(), String> {
        let long = max_pixel.unwrap_or(DEFAULT_MAX_PIXEL).clamp(320, 4096);
        let (w, h) = (long, long * 10 / 16);
        rc_vdisplay::set_monitor(Some((w, h)))?;
        self.restart(Source::VirtualDisplay, long);
        Ok(())
    }

    /// Drop the virtual monitor and follow the frontmost window again. Used by
    /// the phone's "mirror a window" toggle while extended.
    pub fn follow(&mut self) {
        let was_virtual = lock(&self.shared).virtual_display;
        // "Follow" means the frontmost window, so clear any pin too.
        lock(&self.shared).desired = None;
        if was_virtual {
            let _ = rc_vdisplay::set_monitor(None);
            let max_pixel = lock(&self.shared).max_pixel.max(DEFAULT_MAX_PIXEL);
            self.restart(Source::Window, max_pixel); // clears `virtual_display`
        }
    }

    /// Stop streaming and clear the target.
    pub fn stop(&mut self) {
        let was_virtual = {
            let mut s = lock(&self.shared);
            s.running = false;
            s.desired = None;
            s.geometry = None;
            let v = s.virtual_display;
            s.virtual_display = false;
            v
        };
        self.stop_thread();
        if was_virtual {
            // Best effort: a torn-down driver makes this a no-op.
            let _ = rc_vdisplay::set_monitor(None);
        }
    }

    /// Pin to `id`, or follow the frontmost window when `None`. The running
    /// thread picks the change up on its next iteration.
    pub fn select(&mut self, id: Option<String>) {
        let mut s = lock(&self.shared);
        s.desired = id;
    }

    /// The current target frame, for input mapping. `None` when not mirroring.
    pub fn geometry(&self) -> Option<(f64, f64, f64, f64)> {
        lock(&self.shared).geometry
    }

    /// (Re)start the capture thread on `source`. Switching source restarts the
    /// thread, so `run` may treat `virtual_display` as fixed for its lifetime.
    fn restart(&mut self, source: Source, max_pixel: u32) {
        self.stop_thread();
        {
            let mut s = lock(&self.shared);
            s.running = true;
            s.max_pixel = max_pixel;
            s.geometry = None;
            s.virtual_display = source == Source::VirtualDisplay;
        }
        self.stop.store(false, Ordering::SeqCst);
        let session = self.session.clone();
        let shared = self.shared.clone();
        let stop = self.stop.clone();
        self.handle = Some(std::thread::spawn(move || run(session, shared, stop)));
    }

    fn stop_thread(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for MirrorController {
    fn drop(&mut self) {
        self.stop_thread();
    }
}

/// The capture loop. Holds the encoder + last-sent parameter sets privately.
/// Encoder plus the last parameter sets sent, shared by both sources.
///
/// Re-sending identical SPS/PPS makes the phone's decoder rebuild on every
/// frame; caching them is why the two branches can share one encoder.
#[cfg(windows)]
struct EncoderState {
    enc: Option<rc_mirror::ScreenEncoder>,
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
}

#[cfg(windows)]
impl EncoderState {
    fn new() -> Self {
        Self {
            enc: rc_mirror::ScreenEncoder::new(),
            sps: None,
            pps: None,
        }
    }

    /// Encode one BGRA frame and send its NALs.
    fn publish(&mut self, session: &Session, bgra: &[u8], w: u32, h: u32) {
        let Some(enc) = self.enc.as_mut() else { return };
        for nal in enc.encode_bgra(bgra, w, h) {
            let nf = match rc_mirror::nal_type(&nal) {
                7 => {
                    if self.sps.as_ref() == Some(&nal) {
                        continue;
                    }
                    self.sps = Some(nal.clone());
                    NalFrame {
                        kind: NalKind::Sps,
                        data: nal,
                        timestamp_micros: 0,
                    }
                }
                8 => {
                    if self.pps.as_ref() == Some(&nal) {
                        continue;
                    }
                    self.pps = Some(nal.clone());
                    NalFrame {
                        kind: NalKind::Pps,
                        data: nal,
                        timestamp_micros: 0,
                    }
                }
                1 | 5 => NalFrame {
                    kind: NalKind::Video,
                    data: nal,
                    timestamp_micros: 0,
                },
                _ => continue,
            };
            session.send_frame(encode_screen_nal(&nf));
        }
    }
}

/// The capture loop. Its source is fixed for the thread's lifetime (switching
/// source restarts the thread); within the window source, `desired` is read
/// live so pinning takes effect without a restart.
#[cfg(windows)]
fn run(session: Session, shared: Arc<Mutex<Shared>>, stop: Arc<AtomicBool>) {
    let mut enc = EncoderState::new();
    let mut last_target: Option<String> = None;
    let mut last_info = Instant::now() - INFO_INTERVAL;
    // Virtual-display reader state (unused while streaming a window).
    let mut reader: Option<rc_vdisplay::DisplayReader> = None;
    let mut last_seq: u64 = 0;

    while !stop.load(Ordering::SeqCst) {
        let (running, desired, max_pixel, virtual_display) = {
            let s = lock(&shared);
            (s.running, s.desired.clone(), s.max_pixel, s.virtual_display)
        };
        if !running {
            break;
        }

        if virtual_display {
            // Open the ring lazily: the driver may still be starting, and a
            // later iteration will succeed where the first failed.
            if reader.is_none() {
                reader = rc_vdisplay::DisplayReader::open();
            }
            let next = reader
                .as_ref()
                .and_then(|r| r.latest())
                .filter(|f| f.seq != last_seq);
            if let Some(frame) = next {
                last_seq = frame.seq;
                let (w, h) = (frame.width, frame.height);
                // The monitor's desktop rect, so `screenInput` maps correctly.
                // Falls back to the origin when the OS has not laid it out yet.
                let (ox, oy, ow, oh) = rc_vdisplay::find_monitor_rect(w, h)
                    .unwrap_or((0.0, 0.0, w as f64, h as f64));
                lock(&shared).geometry = Some((ox, oy, ow, oh));

                if last_target.as_deref() != Some("extended")
                    || last_info.elapsed() >= INFO_INTERVAL
                {
                    last_info = Instant::now();
                    last_target = Some("extended".to_string());
                    let info = ScreenInfo {
                        status: ScreenStatus::Ok,
                        window_id: Some(format!("extended:{w}x{h}")),
                        // Matches the Mac's extended-display `screenInfo`, which
                        // is what the phone reads to know it is extended.
                        app_id: Some("extended".to_string()),
                        app_name: Some("RemoteCrab Display".to_string()),
                        title: Some("RemoteCrab Display".to_string()),
                        origin_x: ox,
                        origin_y: oy,
                        width: ow,
                        height: oh,
                        pixel_width: w as i64,
                        pixel_height: h as i64,
                        shows_cursor: false,
                    };
                    session.send_frame(encode_screen_info(&info).unwrap_or_default());
                }
                enc.publish(&session, &frame.bgra, w, h);
            }
            std::thread::sleep(FRAME_INTERVAL);
            continue;
        }

        let target = rc_mirror::resolve_target(desired.as_deref());
        let Some(target) = target else {
            {
                let mut s = lock(&shared);
                s.geometry = None;
            }
            if last_target.take().is_some() || last_info.elapsed() >= INFO_INTERVAL {
                last_info = Instant::now();
                let info = ScreenInfo {
                    status: ScreenStatus::NoWindow,
                    window_id: None,
                    app_id: None,
                    app_name: None,
                    title: None,
                    origin_x: 0.0,
                    origin_y: 0.0,
                    width: 0.0,
                    height: 0.0,
                    pixel_width: 0,
                    pixel_height: 0,
                    // Honest, and the reason the iOS side is built for it:
                    // `PrintWindow` renders the *window's* own content and
                    // structurally cannot draw a pointer. Claiming true would
                    // have the phone show a cursor that never moves — or, on
                    // some paths, a stale one captured at start-up, which is
                    // worse than none. The iPhone draws its own dot from the
                    // input it sends, so nothing is lost.
                    shows_cursor: false,
                };
                session.send_frame(encode_screen_info(&info).unwrap_or_default());
            }
            std::thread::sleep(FRAME_INTERVAL);
            continue;
        };

        let geo = target.geometry;
        {
            let mut s = lock(&shared);
            s.geometry = Some((geo.origin_x, geo.origin_y, geo.width, geo.height));
        }

        let captured = rc_mirror::capture_bgra(&target.id, max_pixel);
        let (pixel_w, pixel_h) = match &captured {
            Some((_, w, h)) => (*w as i64, *h as i64),
            None => (0, 0),
        };

        let target_changed = last_target.as_deref() != Some(target.id.as_str());
        if target_changed || last_info.elapsed() >= INFO_INTERVAL {
            last_info = Instant::now();
            last_target = Some(target.id.clone());
            let info = ScreenInfo {
                status: ScreenStatus::Ok,
                window_id: Some(target.id.clone()),
                app_id: Some(target.app_id.clone()),
                app_name: Some(target.app_name.clone()),
                title: Some(target.title.clone()),
                origin_x: geo.origin_x,
                origin_y: geo.origin_y,
                width: geo.width,
                height: geo.height,
                pixel_width: pixel_w,
                pixel_height: pixel_h,
                // See the note above: the transport cannot carry a pointer.
                shows_cursor: false,
            };
            session.send_frame(encode_screen_info(&info).unwrap_or_default());
        }

        if let Some((bgra, w, h)) = captured {
            enc.publish(&session, &bgra, w, h);
        }

        std::thread::sleep(FRAME_INTERVAL);
    }

    // Dropping the target geometry keeps input mapping from firing after stop.
    lock(&shared).geometry = None;
}

/// Window capture is a Win32 API, so on other platforms there is nothing to
/// capture. The thread still has to exist (the controller owns a handle to it)
/// so it just parks until the controller stops it. This keeps the whole crate
/// — including every pure helper and test — buildable and testable off Windows.
#[cfg(not(windows))]
fn run(_session: Session, _shared: Arc<Mutex<Shared>>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Relaxed) {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Regression: a panic on any thread used to poison this mutex, and the
    /// next `lock().unwrap()` on it panicked again — killing the process and the
    /// notification-area icon with it. The guard must come back instead.
    #[test]
    fn lock_recovers_from_a_poisoned_mutex() {
        let m = Arc::new(Mutex::new(Shared::default()));
        let poisoned_by = m.clone();
        let _ = std::thread::spawn(move || {
            let _held = poisoned_by.lock().unwrap();
            panic!("thread panicked while holding the lock");
        })
        .join();
        assert!(m.is_poisoned(), "the test must actually poison the mutex");

        let mut s = lock(&m);
        s.running = true;
        s.geometry = Some((1.0, 2.0, 3.0, 4.0));
        assert!(s.running);
        assert_eq!(s.geometry, Some((1.0, 2.0, 3.0, 4.0)));
    }

    /// The healthy path is unchanged: no poisoning, plain guard.
    #[test]
    fn lock_on_a_healthy_mutex_reads_shared_state() {
        let m = Mutex::new(Shared::default());
        {
            let mut s = lock(&m);
            s.max_pixel = 1280;
        }
        assert_eq!(lock(&m).max_pixel, 1280);
        assert!(!m.is_poisoned());
    }
}
