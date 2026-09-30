//! Telling our own ping echo apart from the peer's.
//!
//! A `ping` frame carries the **sender's** clock and is echoed back verbatim.
//! That makes it a measurement for whoever stamped it, and nothing for the
//! other end: you cannot subtract a peer's timestamp from your own clock and
//! get a round trip, you get the **clock offset between the two machines** —
//! which is normally zero to a few seconds and occasionally several hours.
//!
//! Both ends can now originate probes (the phone measures its own latency, so
//! it sends them), which makes the ambiguity unavoidable: every inbound ping
//! has to be classified before any arithmetic happens. Treating a peer's probe
//! as our own is how a status line ends up advertising "3841 ms" on a LAN.
//!
//! Pure and I/O-free, so the classification is unit-testable on any platform.

/// Discriminates our own echo from a probe the peer originated.
///
/// `last_sent` is deliberately a single value rather than a set: the protocol
/// has one probe outstanding at a time (2 s interval, sub-second round trip), so
/// anything that is not byte-identical to it is the peer's.
#[derive(Debug, Default, Clone, Copy)]
pub struct PingProbe {
    last_sent: Option<u64>,
}

impl PingProbe {
    pub fn new() -> Self {
        PingProbe { last_sent: None }
    }

    /// Stamp and remember an outgoing probe. Returns the payload to send.
    pub fn make_probe(&mut self, now_micros: u64) -> u64 {
        self.last_sent = Some(now_micros);
        now_micros
    }

    /// `true` when `micros` is the echo of a probe we sent — a measurement.
    /// `false` when it is the peer's own probe, which must be echoed back
    /// instead of measured.
    pub fn is_own_echo(&self, micros: u64) -> bool {
        self.last_sent == Some(micros)
    }

    /// Round trip for our own echo, in whole milliseconds. `None` for
    /// anything that is not our echo, so a peer probe can never reach the
    /// arithmetic even by accident.
    pub fn round_trip_ms(&self, of_echo: u64, now_micros: u64) -> Option<i64> {
        let sent = self.last_sent?;
        if of_echo != sent {
            return None;
        }
        Some((now_micros.saturating_sub(sent) / 1000) as i64)
    }

    pub fn reset(&mut self) {
        self.last_sent = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn our_own_echo_is_measured() {
        let mut p = PingProbe::new();
        let sent = p.make_probe(1_000_000);
        assert!(p.is_own_echo(sent));
        assert_eq!(p.round_trip_ms(sent, 1_003_400), Some(3));
    }

    /// The bug this whole module exists for. A probe the phone stamped with
    /// its own clock arrives, and subtracting it from ours yields the offset
    /// between the two clocks — three hours here. Before the fix that number
    /// went straight into the status line.
    #[test]
    fn a_peer_probe_against_a_clock_three_hours_out_is_never_measured() {
        let mut p = PingProbe::new();
        let our_now: u64 = 1_000_000_000_000;
        p.make_probe(our_now);

        // The phone's clock is three hours behind ours.
        let theirs = our_now - 3 * 3_600 * 1_000_000;

        assert!(!p.is_own_echo(theirs), "must not claim a foreign probe");
        assert_eq!(
            p.round_trip_ms(theirs, our_now),
            None,
            "a peer probe must never reach the round-trip arithmetic"
        );
        // …and the number the buggy code would have reported.
        let wrong = (our_now - theirs) / 1000;
        assert_eq!(wrong, 3 * 3_600 * 1000, "that is the value we must not show");
    }

    #[test]
    fn a_probe_from_before_we_ever_sent_one_is_not_ours() {
        let p = PingProbe::new();
        assert!(!p.is_own_echo(12345));
        assert_eq!(p.round_trip_ms(12345, 99_999), None);
    }

    #[test]
    fn only_the_most_recent_probe_is_ours() {
        let mut p = PingProbe::new();
        let first = p.make_probe(1_000);
        let second = p.make_probe(5_000);
        assert!(!p.is_own_echo(first), "a stale echo is not the live probe");
        assert!(p.is_own_echo(second));
    }

    /// A round trip can never be negative if the clocks are sane, and must
    /// saturate rather than wrap if they are not — a negative latency in a
    /// status line is worse than a zero.
    #[test]
    fn a_backwards_clock_saturates_instead_of_wrapping() {
        let mut p = PingProbe::new();
        let sent = p.make_probe(10_000_000);
        assert_eq!(p.round_trip_ms(sent, sent - 5_000_000), Some(0));
    }

    #[test]
    fn reset_forgets_the_probe() {
        let mut p = PingProbe::new();
        let sent = p.make_probe(1_000);
        p.reset();
        assert!(!p.is_own_echo(sent));
    }
}
