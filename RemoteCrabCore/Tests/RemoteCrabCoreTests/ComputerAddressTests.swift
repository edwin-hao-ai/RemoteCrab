import XCTest
import Network
@testable import RemoteCrabCore

final class ComputerAddressTests: XCTestCase {

    func testBonjourBeforeRememberedIP() {
        let out = ComputerAddress.ordered(bonjour: [.host("x.local", 8766)],
                                          remembered: [.host("192.168.1.9", 8766)])
        XCTAssertEqual(out.first, .host("x.local", 8766))
    }

    func testRememberedFollowsBonjourInOrder() {
        let out = ComputerAddress.ordered(
            bonjour: [.host("a.local", 8766)],
            remembered: [.host("192.168.1.9", 8766), .host("192.168.1.10", 8766)])
        XCTAssertEqual(out, [.host("a.local", 8766),
                             .host("192.168.1.9", 8766),
                             .host("192.168.1.10", 8766)])
    }

    func testDedupesRememberedAlreadyInBonjour() {
        let out = ComputerAddress.ordered(
            bonjour: [.host("192.168.1.9", 8766)],
            remembered: [.host("192.168.1.9", 8766), .host("192.168.1.10", 8766)])
        XCTAssertEqual(out, [.host("192.168.1.9", 8766),
                             .host("192.168.1.10", 8766)])
    }

    func testDedupesDuplicatesWithinRemembered() {
        let out = ComputerAddress.ordered(
            bonjour: [],
            remembered: [.host("10.0.0.2", 8766), .host("10.0.0.2", 8766)])
        XCTAssertEqual(out, [.host("10.0.0.2", 8766)])
    }

    func testEmptyInputsYieldEmpty() {
        XCTAssertTrue(ComputerAddress.ordered(bonjour: [], remembered: []).isEmpty)
    }

    func testRememberedOnlyWhenNoBonjour() {
        let out = ComputerAddress.ordered(bonjour: [], remembered: [.host("192.168.1.9", 8766)])
        XCTAssertEqual(out, [.host("192.168.1.9", 8766)])
    }

    /// A Bonjour service endpoint and a remembered IP that happen to resolve
    /// the same machine are different candidates, not duplicates: they are two
    /// genuinely different ways to reach it, so both survive.
    func testBonjourEndpointIsNotDedupedAgainstAHostCandidate() {
        let service = NWEndpoint.hostPort(host: NWEndpoint.Host("10.0.0.5"),
                                          port: NWEndpoint.Port(rawValue: 8766)!)
        let out = ComputerAddress.ordered(bonjour: [.bonjour(service)],
                                          remembered: [.host("10.0.0.5", 8766)])
        XCTAssertEqual(out, [.bonjour(service), .host("10.0.0.5", 8766)])
    }

    func testHostCandidateIsDialable() {
        XCTAssertEqual(ComputerAddress.host("192.168.1.9", 8766).endpoint,
                       NWEndpoint.hostPort(host: NWEndpoint.Host("192.168.1.9"),
                                           port: NWEndpoint.Port(rawValue: 8766)!))
    }

    func testBonjourCandidateDialsItsOwnEndpoint() {
        let service = NWEndpoint.hostPort(host: NWEndpoint.Host("10.0.0.5"),
                                          port: NWEndpoint.Port(rawValue: 8766)!)
        XCTAssertEqual(ComputerAddress.bonjour(service).endpoint, service)
    }
}
