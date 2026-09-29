//! App-window mirror (Windows): capture the frontmost (or pinned) window,
//! H.264-encode it, and stream it to the iPhone as `screenSps`/`screenPps`/
//! `screenVideo` + `screenInfo` (kinds `0x1A`–`0x1C`/`0x1F`).
//!
//! The capture/encode loop runs on a dedicated thread because `PrintWindow`
//! and OpenH264 are blocking and CPU-bound; input (`screenInput`) stays on
//! the async loop, which reads the target geometry from [`MirrorController`].

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rc_net::Session;
use rc_protocol::{
    encode_screen_info, encode_screen_nal, NalFrame, NalKind, ScreenInfo, ScreenStatus,
};

const FRAME_INTERVAL: Duration = Duration::from_millis(33); // ~30 fps
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
}

/// Lock that survives a poisoned mutex.
///
/// A panic elsewhere can never leave `Shared` half-written (it is three plain
/// fields plus an `Option`), so the data is still valid — but `lock().unwrap()`
/// would turn that unrelated panic into a second one, and in a tray app a panic
/// anywhere takes the whole process (notification area and all) with it. Recover
/// the guard instead of propagating.
fn lock(shared: &Mutex<Shared>) -> std::sync::MutexGuard<'_, Shared> {
    shared.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Owns the mirror capture thread. Cheap to keep for the app's lifetime.
pub struct MirrorController {
    session: Session,
    shared: Arc<Mutex<Shared>>,
    stop: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
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
            })),
            stop: Arc::new(AtomicBool::new(false)),
            handle: None,
        }
    }

    /// Start (or restart) streaming. `max_pixel` is the phone's long-edge cap.
    pub fn start(&mut self, max_pixel: Option<u32>) {
        self.stop_thread();
        let max_pixel = max_pixel.unwrap_or(DEFAULT_MAX_PIXEL).clamp(320, 4096);
        {
            let mut s = lock(&self.shared);
            s.running = true;
            s.max_pixel = max_pixel;
            s.geometry = None;
        }
        self.stop.store(false, Ordering::SeqCst);
        let session = self.session.clone();
        let shared = self.shared.clone();
        let stop = self.stop.clone();
        self.handle = Some(std::thread::spawn(move || run(session, shared, stop)));
    }

    /// Stop streaming and clear the target.
    pub fn stop(&mut self) {
        {
            let mut s = lock(&self.shared);
            s.running = false;
            s.desired = None;
            s.geometry = None;
        }
        self.stop_thread();
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
fn run(session: Session, shared: Arc<Mutex<Shared>>, stop: Arc<AtomicBool>) {
    let mut encoder = rc_mirror::ScreenEncoder::new();
    let mut last_sps: Option<Vec<u8>> = None;
    let mut last_pps: Option<Vec<u8>> = None;
    let mut last_target: Option<String> = None;
    let mut last_info = Instant::now() - INFO_INTERVAL;

    while !stop.load(Ordering::SeqCst) {
        let (running, desired, max_pixel) = {
            let s = lock(&shared);
            (s.running, s.desired.clone(), s.max_pixel)
        };
        if !running {
            break;
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
                    shows_cursor: true,
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
                shows_cursor: true,
            };
            session.send_frame(encode_screen_info(&info).unwrap_or_default());
        }

        if let (Some(enc), Some((bgra, w, h))) = (encoder.as_mut(), captured) {
            for nal in enc.encode_bgra(&bgra, w, h) {
                let nf = match rc_mirror::nal_type(&nal) {
                    7 => {
                        // Skip re-sending identical parameter sets (the iOS
                        // decoder would otherwise rebuild every keyframe).
                        if last_sps.as_ref() == Some(&nal) {
                            continue;
                        }
                        last_sps = Some(nal.clone());
                        NalFrame { kind: NalKind::Sps, data: nal, timestamp_micros: 0 }
                    }
                    8 => {
                        if last_pps.as_ref() == Some(&nal) {
                            continue;
                        }
                        last_pps = Some(nal.clone());
                        NalFrame { kind: NalKind::Pps, data: nal, timestamp_micros: 0 }
                    }
                    1 | 5 => NalFrame { kind: NalKind::Video, data: nal, timestamp_micros: 0 },
                    _ => continue,
                };
                session.send_frame(encode_screen_nal(&nf));
            }
        }

        std::thread::sleep(FRAME_INTERVAL);
    }

    // Dropping the target geometry keeps input mapping from firing after stop.
    lock(&shared).geometry = None;
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
