//! Opus decoding via libopus (bundled — no system dependency).
//!
//! The iOS sender uses 48 kHz mono, 20 ms packets (960 frames). A corrupt
//! packet returns an empty vec so the caller drops it rather than poisoning
//! the decoder (matching the Mac receiver's behaviour).

/// 48 kHz is the only rate the sender uses (Opus is internally 48 kHz).
pub const SAMPLE_RATE: u32 = 48_000;
/// 20 ms at 48 kHz — the sender's packet size.
pub const FRAME_SIZE: usize = 960;

pub struct OpusDecoder {
    decoder: opus_decoder::OpusDecoder,
    scratch: Vec<i16>,
}

impl OpusDecoder {
    pub fn new() -> Result<Self, opus_decoder::OpusError> {
        let decoder = opus_decoder::OpusDecoder::new(SAMPLE_RATE, 1)?;
        let scratch = vec![0i16; opus_decoder::OpusDecoder::MAX_FRAME_SIZE_48K];
        Ok(OpusDecoder { decoder, scratch })
    }

    /// Decode one Opus packet into Int16 mono samples at 48 kHz.
    /// Returns empty on a corrupt/empty packet.
    pub fn decode(&mut self, packet: &[u8]) -> Vec<i16> {
        if packet.is_empty() {
            return Vec::new();
        }
        match self.decoder.decode(packet, &mut self.scratch, false) {
            Ok(frames) => self.scratch[..frames].to_vec(),
            Err(_) => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decoder_constructs() {
        assert!(OpusDecoder::new().is_ok());
    }

    #[test]
    fn empty_packet_yields_nothing() {
        let mut d = OpusDecoder::new().unwrap();
        assert!(d.decode(&[]).is_empty());
    }

    #[test]
    fn garbage_packet_does_not_panic() {
        let mut d = OpusDecoder::new().unwrap();
        // Random bytes are not a valid Opus packet; must return empty, not panic.
        let _ = d.decode(&[0xFF; 40]);
    }

    #[test]
    fn decodes_a_real_opus_packet() {
        // Use the embedded 440 Hz tone packets — real libopus output, so this
        // proves we can decode what the iOS sender produces.
        let packet = crate::tone_data::TONE_PACKETS[0];
        let mut decoder = OpusDecoder::new().unwrap();
        let decoded = decoder.decode(packet);
        assert!(!decoded.is_empty(), "a real Opus packet should decode");
        assert!(
            rms_like(&decoded) > 0.01,
            "the 440 Hz tone came back silent"
        );
    }

    #[test]
    fn decodes_a_whole_tone_sequence() {
        let mut decoder = OpusDecoder::new().unwrap();
        let mut total = 0usize;
        for packet in crate::tone_data::TONE_PACKETS {
            let d = decoder.decode(packet);
            if !d.is_empty() {
                total += d.len();
            }
        }
        // ~30 packets * 960 samples, minus Opus pre-skip on the first.
        assert!(total > 27_000, "decoded only {total} samples");
    }

    fn rms_like(samples: &[i16]) -> f32 {
        let sum: f64 = samples.iter().map(|&s| (s as f64) * (s as f64)).sum();
        ((sum / samples.len() as f64).sqrt() / 32768.0) as f32
    }
}
