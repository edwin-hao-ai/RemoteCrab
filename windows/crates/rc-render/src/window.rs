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

/// How many superseded buffers to keep alive.
///
/// [`minifb::Window::update_with_buffer`] does not copy. On Windows it stores
/// the pointer it was given in `draw_params.buffer`, asks for a repaint with
/// `InvalidateRect`, and dereferences that pointer later, inside the `WM_PAINT`
/// handler. `InvalidateRect` plus the message loop is not a guarantee that the
/// paint happens before the call returns — a covered or minimized window defers
/// `WM_PAINT` indefinitely.
///
/// So a buffer handed to `update_with_buffer` must stay alive for as long as a
/// paint might still reference it. Dropping it early leaves minifb reading freed
/// memory, which is what painted the band of coloured noise across the top of
/// the preview: rotating the phone changes the frame size, the resize path
/// replaced the buffer, and the pending paint read the old, freed allocation.
/// Retaining a few superseded buffers covers the deferred-paint window without
/// letting the process grow without bound.
const RETAIN_SUPERSEDED: usize = 4;

/// Owns the buffer handed to `minifb`, keeping superseded ones alive.
///
/// Extracted from the window loop so the lifetime rule can be stated once and
/// tested without a display.
#[derive(Debug, Default)]
struct BlitBuffer {
    current: Vec<u32>,
    /// Buffers `minifb` may still be holding a pointer into.
    retained: Vec<Vec<u32>>,
    size: (usize, usize),
}

impl BlitBuffer {
    fn new() -> Self {
        Self::default()
    }

    /// The slice to hand to `update_with_buffer`. Its contents must not change
    /// while the call is in flight.
    fn pixels(&self) -> &[u32] {
        &self.current
    }

    fn size(&self) -> (usize, usize) {
        self.size
    }

    /// Resize if needed, retiring the buffer just handed out.
    ///
    /// Retiring rather than dropping is the whole point: see
    /// [`RETAIN_SUPERSEDED`].
    fn resize(&mut self, width: usize, height: usize) -> bool {
        if self.size == (width, height) && self.current.len() == width * height {
            return false;
        }
        if !self.current.is_empty() {
            self.retained.push(std::mem::replace(
                &mut self.current,
                vec![0u32; width * height],
            ));
            if self.retained.len() > RETAIN_SUPERSEDED {
                self.retained.remove(0);
            }
        } else {
            self.current = vec![0u32; width * height];
        }
        self.size = (width, height);
        true
    }

    /// True while a buffer previously handed to `minifb` is still owned here.
    #[cfg(test)]
    fn holds_superseded(&self) -> bool {
        !self.retained.is_empty()
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
    let mut blit = BlitBuffer::new();
    blit.resize(960, 540);

    let mut window = match Window::new(
        title,
        960,
        540,
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
                blit.resize(fw, fh);
                last_size = (fw, fh);
                window.set_title(&format!("{title} — {fw}x{fh}"));
            }
            // `RgbaFrame.pixels` is a public field, so a caller can hand over a
            // slice that does not match `width * height`. `resize` short-circuits
            // when the size has not changed, so a mismatched frame at a size we
            // are already painting would panic here and take the window thread
            // with it — on a thread nobody is watching.
            if frame.pixels.len() == blit.current.len() {
                blit.current.copy_from_slice(&frame.pixels);
                painted = true;
            }
        } else if !painted {
            // No video yet: draw a calm "waiting" background.
            let status_text = status.lock().map(|s| s.clone()).unwrap_or_default();
            window.set_title(&format!("{title} — {status_text}"));
            for px in blit.current.iter_mut() {
                *px = 0x00101014;
            }
        }

        let (w, h) = blit.size();
        if let Err(e) = window.update_with_buffer(blit.pixels(), w, h) {
            eprintln!("preview window update failed: {e}");
            break;
        }
        std::thread::sleep(Duration::from_millis(16));
    }
}

#[cfg(test)]
mod tests {
    use super::{BlitBuffer, FrameSlot, RETAIN_SUPERSEDED};
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

    /// The invariant that keeps `minifb` from reading freed memory.
    ///
    /// `update_with_buffer` stores the pointer it is given and dereferences it
    /// later, inside `WM_PAINT`, which `InvalidateRect` does not guarantee runs
    /// before the call returns. So after a size change the buffer that was just
    /// handed over must still be owned — a resize that drops it leaves a dangling
    /// pointer in the window, and the next paint reads freed memory.
    #[test]
    fn a_resize_keeps_the_buffer_that_was_handed_over_alive() {
        let mut blit = BlitBuffer::new();
        blit.resize(4, 4);
        for (i, px) in blit.current.iter_mut().enumerate() {
            *px = 0xAAAA_0000 | i as u32;
        }
        let handed_over = blit.pixels().as_ptr();

        // Rotate the phone: new dimensions, so the old buffer is superseded.
        assert!(blit.resize(8, 8), "a real size change must report a resize");
        assert_eq!(blit.size(), (8, 8));

        // The superseded buffer must still be ours, at the same address, with its
        // contents intact — that is what a paint still in flight will read.
        assert!(
            blit.holds_superseded(),
            "the buffer just handed to minifb was dropped; a deferred WM_PAINT \
             would read freed memory and paint garbage"
        );
        let survivor = blit
            .retained
            .iter()
            .find(|b| b.as_ptr() == handed_over)
            .expect("the superseded buffer was reallocated, not retained");
        assert_eq!(survivor.len(), 16);
        for (i, &px) in survivor.iter().enumerate() {
            assert_eq!(px, 0xAAAA_0000 | i as u32, "survivor was overwritten");
        }
    }

    /// Rotation is not the only resize, and a caller must not be able to grow the
    /// process without bound by cycling sizes.
    #[test]
    fn retained_buffers_stay_bounded() {
        let mut blit = BlitBuffer::new();
        for n in 2..40usize {
            blit.resize(n, n);
        }
        assert!(
            blit.retained.len() <= RETAIN_SUPERSEDED,
            "retained {} buffers, cap is {RETAIN_SUPERSEDED}",
            blit.retained.len()
        );
    }

    /// Most frames arrive at the same size; retiring a buffer every frame would
    /// churn an 8.3 MB allocation per frame at live resolution.
    #[test]
    fn a_steady_size_retires_nothing() {
        let mut blit = BlitBuffer::new();
        blit.resize(6, 4);
        let ptr = blit.pixels().as_ptr();
        for _ in 0..30 {
            assert!(!blit.resize(6, 4), "same size must not report a resize");
            assert_eq!(blit.pixels().as_ptr(), ptr, "buffer was reallocated");
        }
        assert!(!blit.holds_superseded());
    }

    /// The window loop must never be handed a slice that does not match the size
    /// it claims, which `minifb` turns into an unsound read rather than an error.
    #[test]
    fn the_handed_slice_matches_the_reported_size() {
        let mut blit = BlitBuffer::new();
        for (w, h) in [(4usize, 4usize), (1920, 1080), (1080, 1920), (2, 2)] {
            blit.resize(w, h);
            let (rw, rh) = blit.size();
            assert_eq!(blit.pixels().len(), rw * rh, "size {rw}x{rh}");
            assert!(blit.pixels().len() >= rw * rh);
        }
    }
}
