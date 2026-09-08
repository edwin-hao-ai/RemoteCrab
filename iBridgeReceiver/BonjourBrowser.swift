import Foundation
import Network
import iBridgeCore

/// Wraps `NWBrowser` to discover iPhones advertising the iBridge
/// service type. The browser runs on a background queue and reports
/// results through `onChange`.
final class BonjourBrowser: @unchecked Sendable {

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.ibridge.browser")

    func start(serviceType: String, onChange: @escaping @MainActor @Sendable ([DiscoveredPhone]) -> Void) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[iBridge] browser ready for \(serviceType)")
            case .failed(let error):
                print("[iBridge] browser failed: \(error)")
            default:
                break
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            self?.collectPhones(from: results, onChange: onChange)
        }

        browser?.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func collectPhones(from results: Set<NWBrowser.Result>,
                               onChange: @escaping @MainActor @Sendable ([DiscoveredPhone]) -> Void) {
        var phones: [DiscoveredPhone] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }

            // The metadata type may vary between SDK versions; try
            // both the modern and legacy shapes.
            var hostString: String?
            var portNumber: UInt16?

            if case let .bonjour(record) = result.metadata {
                let txt = record.dictionary
                _ = txt
                // We can resolve via TXT record but for V0.1 just store name+0
            }

            // Fallback: try `case .ipv4` / `.ipv6` / `.name` patterns
            // (the SDK exposes metadata cases as a synthetic enum).
            let endpointDesc = "\(result.endpoint)"
            if endpointDesc.contains(":"),
               let lastColon = endpointDesc.lastIndex(of: ":") {
                let after = endpointDesc[endpointDesc.index(after: lastColon)...]
                portNumber = UInt16(after)
                hostString = String(endpointDesc[..<lastColon])
                    .replacingOccurrences(of: "Endpoint", with: "")
                    .replacingOccurrences(of: "host=", with: "")
            }

            phones.append(DiscoveredPhone(
                id: "\(name):\(portNumber ?? 0)",
                name: name,
                endpoint: hostString ?? endpointDesc,
                port: portNumber ?? 0
            ))
        }

        Task { @MainActor in
            onChange(phones)
        }
    }
}