//! A minimal preview window (`minifb`) that blits the latest decoded frame.
//!
//! Runs on the calling thread and returns when the user closes it or the
//! app signals shutdown — the session runs on another thread, so the UI
//! never blocks the network path.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use minifb::{Key, Window, WindowOptions};

use crate::decoder::RgbaFrame;

/// A thread-safe slot holding the most recent frame.
#[derive(Clone, Default)]
pub struct FrameSlot(Arc<Mutex<Option<RgbaFrame>>>);

impl FrameSlot {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&self, frame: RgbaFrame) {
        if let Ok(mut slot) = self.0.lock() {
            *slot = Some(frame);
        }
    }

    pub fn get(&self) -> Option<RgbaFrame> {
        self.0.lock().ok().and_then(|s| s.clone())
    }
}

/// Open a preview window and keep it updated from `slot` until closed.
///
/// `shutdown` is set by the app to close the window programmatically.
pub fn run_preview_window(
    title: &str,
    slot: FrameSlot,
    shutdown: Arc<AtomicBool>,
    status: Arc<Mutex<String>>,
) {
    // Start with a placeholder size; resize to the video on the first frame.
    let mut width = 960usize;
    let mut height = 540usize;
    let mut buffer = vec![0u32; width * height];

    let mut window = match Window::new(
        title,
        width,
        height,
        WindowOptions {
            resize: true,
            scale: minifb::Scale::X1,
            ..WindowOptions::default()
        },
    ) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("could not open preview window: {e}");
            return;
        }
    };
    window.set_target_fps(60);

    let mut last_size = (0usize, 0usize);
    let mut painted = false;

    while window.is_open() && !window.is_key_down(Key::Escape) && !shutdown.load(Ordering::Relaxed)
    {
        if let Some(frame) = slot.get() {
            let (fw, fh) = (frame.width as usize, frame.height as usize);
            if (fw, fh) != last_size {
                width = fw;
                height = fh;
                buffer = vec![0u32; width * height];
                last_size = (fw, fh);
                window.set_title(&format!("{title} — {fw}x{fh}"));
            }
            buffer.copy_from_slice(&frame.pixels);
            painted = true;
        } else if !painted {
            // No video yet: draw a calm "waiting" background.
            let status_text = status.lock().map(|s| s.clone()).unwrap_or_default();
            window.set_title(&format!("{title} — {status_text}"));
            for px in buffer.iter_mut() {
                *px = 0x00101014;
            }
        }

        if let Err(e) = window.update_with_buffer(&buffer, width, height) {
            eprintln!("preview window update failed: {e}");
            break;
        }
        std::thread::sleep(Duration::from_millis(16));
    }
}
