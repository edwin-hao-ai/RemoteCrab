import XCTest
@testable import RemoteCrabCore

/// The mutual challenge-response that stops a same-LAN impostor from being taken
/// for a computer (see `docs/HANDOFF-IOS-PEER-AUTH.md`).
///
/// The two pinned vectors below are the **cross-language contract**. The Rust
/// receiver pins the same pair in
/// `rc-protocol/src/peer_auth.rs::the_wire_format_is_pinned_for_the_other_language`.
/// If either side's bytes change, these move in the same change — otherwise the
/// two ends silently stop recognising each other and it looks like a network
/// fault.
final class PeerAuthTests: XCTestCase {

    // MARK: - Pinned cross-language vectors

    func testPinnedServerMacMatchesTheRustReceiver() {
        XCTAssertEqual(
            PeerAuth.serverMac(token: "pin-token", pcID: "pin-pc",
                               clientNonce: "pin-c", serverNonce: "pin-s"),
            "mk6oqPyEKo9XCtvvvYQhTx1jDlC62M2JOi974PubYRA="
        )
    }

    func testPinnedClientMacMatchesTheRustReceiver() {
        XCTAssertEqual(
            PeerAuth.clientMac(token: "pin-token", pcID: "pin-pc",
                               clientNonce: "pin-c", serverNonce: "pin-s"),
            "8DT4HKeN9V5qqo+lrkRYhCTXeFVfpqcQLY0CBFj3WFg="
        )
    }

    // MARK: - The properties the exchange exists for

    func testTheWrongTokenDoesNotMatch() {
        let mine = PeerAuth.serverMac(token: "tok", pcID: "pc", clientNonce: "c", serverNonce: "s")
        let theirs = PeerAuth.serverMac(token: "other", pcID: "pc", clientNonce: "c", serverNonce: "s")
        XCTAssertFalse(PeerAuth.matches(expected: mine, presented: theirs))
    }

    /// Without the separate labels, a phone could bounce the receiver's own
    /// proof back at it and be believed. This is that attack, asserted against.
    func testTheClientMacIsNotAcceptedAsAServerMac() {
        let asClient = PeerAuth.clientMac(token: "tok", pcID: "pc", clientNonce: "c", serverNonce: "s")
        let expectedServer = PeerAuth.serverMac(token: "tok", pcID: "pc", clientNonce: "c", serverNonce: "s")
        XCTAssertNotEqual(asClient, expectedServer)
        XCTAssertFalse(PeerAuth.matches(expected: expectedServer, presented: asClient))
    }

    /// A fresh nonce changes the MAC, which is what makes a recorded exchange
    /// useless to a listener on the next connection.
    func testTheNonceChangesTheMac() {
        let first = PeerAuth.serverMac(token: "tok", pcID: "pc", clientNonce: "c", serverNonce: "s1")
        let second = PeerAuth.serverMac(token: "tok", pcID: "pc", clientNonce: "c", serverNonce: "s2")
        XCTAssertNotEqual(first, second)
    }

    /// The machine id is part of the MAC, so a proof collected for one computer
    /// cannot be replayed as another.
    func testTheMachineIDIsPartOfTheMac() {
        XCTAssertNotEqual(
            PeerAuth.serverMac(token: "tok", pcID: "pc-a", clientNonce: "c", serverNonce: "s"),
            PeerAuth.serverMac(token: "tok", pcID: "pc-b", clientNonce: "c", serverNonce: "s")
        )
    }

    /// The NUL separator is load-bearing: without it `("a","bc")` and `("ab","c")`
    /// hash the same bytes.
    func testFieldsCannotBeShiftedAcrossTheBoundary() {
        XCTAssertNotEqual(
            PeerAuth.serverMac(token: "tok", pcID: "ab", clientNonce: "c", serverNonce: "s"),
            PeerAuth.serverMac(token: "tok", pcID: "a", clientNonce: "bc", serverNonce: "s")
        )
    }

    func testMatchesRejectsDifferentLengths() {
        let mac = PeerAuth.serverMac(token: "tok", pcID: "pc", clientNonce: "a", serverNonce: "b")
        XCTAssertEqual(mac.count, 44)
        XCTAssertFalse(PeerAuth.matches(expected: mac, presented: String(mac.dropLast())))
        XCTAssertFalse(PeerAuth.matches(expected: mac, presented: ""))
        XCTAssertFalse(PeerAuth.matches(expected: "", presented: mac))
    }

    // MARK: - Nonces

    func testNonceIs44CharsAndDoesNotRepeat() {
        var seen = Set<String>()
        for _ in 0..<1000 {
            let nonce = PeerAuth.newNonce()
            XCTAssertEqual(nonce.count, 44)
            XCTAssertTrue(seen.insert(nonce).inserted, "a nonce came up twice")
        }
    }

    func testTheCapabilityIsTheAgreedString() {
        XCTAssertEqual(PeerAuth.capability, "peerAuth")
    }
}
