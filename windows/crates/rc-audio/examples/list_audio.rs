//! Print the machine's audio device names as `cpal` sees them, and what
//! `pick_virtual_cable` would choose. A diagnostic, not part of the app.
//!
//! Run: `cargo run -p rc-audio --example list_audio`

use cpal::traits::HostTrait;

fn main() {
    let host = cpal::default_host();
    println!("=== output (render) devices ===");
    if let Ok(devices) = host.output_devices() {
        for d in devices {
            println!("  {d}");
        }
    }
    println!("=== input (capture) devices ===");
    if let Ok(devices) = host.input_devices() {
        for d in devices {
            println!("  {d}");
        }
    }
    println!(
        "pick_virtual_cable -> {:?}",
        rc_audio::pick_virtual_cable(&rc_audio::output_device_names())
    );
}
