import Foundation
import MetricKit
import os

/// On-device crash + performance diagnostics (D1).
///
/// Deliberately **no third party and no network**: MetricKit hands the app its
/// own crash, hang and metric payloads on-device, and this writes them to
/// `os_log` (subsystem `com.remotecrab`) and the forensic file. The product's
/// whole pitch is "no cloud", so there is no upload path — a developer with
/// the device (or a bug report with the log) can see *why* the app restarted,
/// which is strictly more than the zero visibility we had before.
///
/// MetricKit delivers payloads roughly once a day, so this is a background
/// safety net, not a live channel.
public final class MetricsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    public static let shared = MetricsReporter()

    private static let log = Logger(subsystem: "com.remotecrab", category: "metrics")

    private var started = false

    /// Subscribe. Idempotent; safe to call from app launch.
    public func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        Self.log.info("MetricKit subscriber registered")
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let json = payload.jsonRepresentation()
            Self.log.info("received \(payloads.count) metric payload(s), \(json.count) bytes")
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let reason = crash.terminationReason ?? "unknown"
                let exception = crash.exceptionType.map { String(describing: $0) } ?? "-"
                Self.log.error("crash diagnostic: reason=\(reason, privacy: .public) exception=\(exception, privacy: .public)")
                Forensic.log("[metrics] crash reason=\(reason) exception=\(exception)")
            }
            for hang in payload.hangDiagnostics ?? [] {
                let ms = hang.hangDuration.converted(to: .milliseconds).value
                Self.log.error("hang diagnostic: ~\(Int(ms), privacy: .public) ms")
                Forensic.log("[metrics] hang ~\(Int(ms))ms")
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                let ms = cpu.totalCPUTime.converted(to: .milliseconds).value
                Self.log.error("cpu exception diagnostic: ~\(Int(ms), privacy: .public) ms CPU")
                Forensic.log("[metrics] cpu exception ~\(Int(ms))ms")
            }
        }
    }
}
