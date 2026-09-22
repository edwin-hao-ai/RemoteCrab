import XCTest
@testable import RemoteCrabCore

final class SerialFileSenderTests: XCTestCase {

    /// Records send start/end so the test can assert ordering and that
    /// two sends never overlap.
    private actor Recorder {
        private(set) var order: [String] = []
        private var concurrent = 0
        private(set) var maxConcurrent = 0

        func begin(_ name: String) {
            order.append(name)
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
        }

        func end() { concurrent -= 1 }

        var snapshot: (order: [String], maxConcurrent: Int) { (order, maxConcurrent) }
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func testSendsInOrderWithoutOverlap() async {
        let sender = SerialFileSender()
        let recorder = Recorder()
        await sender.enqueue([url("a"), url("b"), url("c")]) { u in
            await recorder.begin(u.lastPathComponent)
            try? await Task.sleep(nanoseconds: 15_000_000)
            await recorder.end()
        }
        await sender.drain()

        let snap = await recorder.snapshot
        XCTAssertEqual(snap.order, ["a", "b", "c"])
        XCTAssertEqual(snap.maxConcurrent, 1)
    }

    func testSecondEnqueueWaitsForFirst() async {
        let sender = SerialFileSender()
        let recorder = Recorder()
        let send: @Sendable (URL) async -> Void = { u in
            await recorder.begin(u.lastPathComponent)
            try? await Task.sleep(nanoseconds: 25_000_000)
            await recorder.end()
        }
        await sender.enqueue([url("a")], send)
        await sender.enqueue([url("b")], send)
        await sender.drain()

        let snap = await recorder.snapshot
        XCTAssertEqual(snap.order, ["a", "b"])
        XCTAssertEqual(snap.maxConcurrent, 1)
    }

    func testEmptyEnqueueIsHarmless() async {
        let sender = SerialFileSender()
        await sender.enqueue([], { _ in })
        await sender.drain()
    }
}
