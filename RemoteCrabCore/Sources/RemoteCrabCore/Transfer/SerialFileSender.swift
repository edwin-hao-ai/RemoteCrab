import Foundation

/// Serializes file sends to the Mac.
///
/// The wire protocol carries one file at a time (`fileOffer` → raw
/// `fileChunk`s → `fileComplete`), with no per-file stream id — two files
/// sent concurrently would interleave chunk frames and corrupt both.
/// Enqueued URLs are therefore sent strictly one after another: the next
/// starts only after the previous send closure returns.
public actor SerialFileSender {

    public typealias Send = @Sendable (URL) async -> Void

    private var tail: Task<Void, Never>?

    public init() {}

    /// Append `urls` to the queue. They run in order after everything
    /// already queued. Empty input is a no-op.
    public func enqueue(_ urls: [URL], _ send: @escaping Send) {
        guard !urls.isEmpty else { return }
        let previous = tail
        tail = Task {
            await previous?.value
            for url in urls { await send(url) }
        }
    }

    /// Wait until every currently-queued send has finished.
    public func drain() async {
        await tail?.value
    }
}
