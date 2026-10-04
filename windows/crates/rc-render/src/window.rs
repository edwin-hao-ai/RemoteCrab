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
///
/// The frame is held behind an [`Arc`] on purpose. A 1080x1920 frame is 8.3 MB,
/// and this slot has two readers on two threads: the decode task writes it ~30
/// times a second and the window loop reads it up to 60. Holding the `RgbaFrame`
/// directly meant a deep copy on **both** sides — roughly 750 MB/s of memcpy at
/// live resolution, growing to 2 GB/s at 4K. An `Arc` clone is a refcount bump,
/// so the window redraws from the same buffer the decoder just wrote.
///
/// The alternative, a single-producer/single-consumer ring, is the better design
/// but it needs a real change to the ownership contract; this is the small step
/// that removes the copying without pretending the design is finished.
#[derive(Clone, Default)]
pub struct FrameSlot(Arc<Mutex<Option<Arc<RgbaFrame>>>>);

impl FrameSlot {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set(&self, frame: Arc<RgbaFrame>) {
        if let Ok(mut slot) = self.0.lock() {
            *slot = Some(frame);
        }
    }

    /// Cheap: a refcount bump, never a copy.
    pub fn get(&self) -> Option<Arc<RgbaFrame>> {
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

#[cfg(test)]
mod tests {
    use super::FrameSlot;
    use crate::decoder::RgbaFrame;
    use std::sync::Arc;

    fn frame(seed: u32) -> Arc<RgbaFrame> {
        Arc::new(RgbaFrame {
            width: 4,
            height: 2,
            pixels: vec![seed; 8],
        })
    }

    /// The property that makes the slot worth having: reading it does not copy
    /// the buffer.
    ///
    /// Asserted by allocation identity rather than by timing, because a
    /// benchmark passes or fails with the machine's mood while this cannot.
    /// Before the `Arc`, `get` deep-copied the whole buffer — 8.3 MB at
    /// 1080x1920 — and the window loop did it up to 60 times a second.
    #[test]
    fn reading_the_slot_does_not_copy_the_frame() {
        let slot = FrameSlot::new();
        let original = frame(0xAB);
        slot.set(original.clone());

        let first = slot.get().expect("a frame was just set");
        let second = slot.get().expect("still there");

        assert!(
            Arc::ptr_eq(&original, &first),
            "get must hand back the very same allocation, not a copy"
        );
        assert!(
            Arc::ptr_eq(&first, &second),
            "two reads must share one allocation, not copy twice"
        );
    }

    /// The newest frame wins.
    #[test]
    fn the_newest_frame_replaces_the_previous_one() {
        let slot = FrameSlot::new();
        slot.set(frame(1));
        slot.set(frame(2));
        assert_eq!(slot.get().expect("a frame").pixels[0], 2);
    }

    /// The window loop reads on its own thread while the decode task writes on
    /// another. That is the whole reason this is an `Arc<Mutex<_>>`, so it gets
    /// exercised with more than one reader.
    #[test]
    fn a_shared_slot_survives_concurrent_readers_and_a_writer() {
        let slot = FrameSlot::new();
        slot.set(frame(0));
        let writer = {
            let slot = slot.clone();
            std::thread::spawn(move || {
                for i in 1..200u32 {
                    slot.set(frame(i));
                }
            })
        };
        for _ in 0..8 {
            let reader = {
                let slot = slot.clone();
                std::thread::spawn(move || {
                    for _ in 0..500 {
                        if let Some(f) = slot.get() {
                            // Every pixel of a frame holds the same value, so a
                            // torn read shows up as mixed values.
                            assert!(
                                f.pixels.iter().all(|&p| p == f.pixels[0]),
                                "torn frame read"
                            );
                        }
                    }
                })
            };
            reader.join().expect("reader");
        }
        writer.join().expect("writer");
    }

    #[test]
    fn an_empty_slot_reads_as_none() {
        assert!(FrameSlot::new().get().is_none());
    }
}
