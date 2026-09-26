import AppKit
import CoreGraphics
import Foundation
import os

/// A real extra macOS display, created with the private `CGVirtualDisplay`
/// classes that every third-party "second display" app (Duet, Luna,
/// BetterDisplay) uses. No driver, no kext, no entitlement — but the classes
/// are undocumented, so they are isolated here, every step is logged, and
/// `create()` returns only once CoreGraphics has actually registered the
/// display. Releasing the object removes the display again.
///
/// Verified on this project's dev machine: create() → a new
/// `CGGetActiveDisplayList` entry, and `SCStream` captures real frames from
/// it (see the spike in the session notes).
@MainActor
final class VirtualDisplay {
    private static let log = Logger(subsystem: "com.remotecrab", category: "virtualdisplay")

    private var display: AnyObject?
    private(set) var displayID: CGDirectDisplayID?

    /// Create a `width`×`height` @ 60 Hz display and return the id
    /// CoreGraphics assigned, or nil when the private API is unavailable
    /// (a future macOS) or the display never registers.
    func create(width: Int, height: Int) async -> CGDirectDisplayID? {
        if displayID != nil { return displayID }

        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
            Self.log.error("CGVirtualDisplay classes unavailable on this macOS — extend unsupported")
            return nil
        }

        let before = Self.activeDisplays()

        let descriptor = descriptorClass.init()
        descriptor.setValue("RemoteCrab Display", forKey: "name")
        descriptor.setValue(width, forKey: "maxPixelsWide")
        descriptor.setValue(height, forKey: "maxPixelsHigh")
        // Physical size only drives the default scaling; ~24-inch proportions.
        descriptor.setValue(
            NSValue(size: NSSize(width: 500, height: max(1, 500 * height / max(width, 1)))),
            forKey: "sizeInMillimeters"
        )
        descriptor.setValue(0x1DEA, forKey: "productID")
        descriptor.setValue(0x1DEA, forKey: "vendorID")
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        let allocated = displayClass
            .perform(NSSelectorFromString("alloc"))!
            .takeUnretainedValue() as AnyObject
        guard let created = allocated
            .perform(NSSelectorFromString("initWithDescriptor:"), with: descriptor)?
            .takeUnretainedValue() as AnyObject? else {
            Self.log.error("CGVirtualDisplay init failed")
            return nil
        }

        let mode = modeClass.init()
        mode.setValue(width, forKey: "width")
        mode.setValue(height, forKey: "height")
        mode.setValue(60.0, forKey: "refreshRate")
        let settings = settingsClass.init()
        settings.setValue(0, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        created.perform(NSSelectorFromString("applySettings:"), with: settings)
        display = created

        // CoreGraphics registers the display asynchronously.
        for _ in 0..<20 {
            if let id = Self.activeDisplays().subtracting(before).first {
                displayID = id
                Self.log.info("virtual display created id=\(id, privacy: .public) \(width, privacy: .public)x\(height, privacy: .public)")
                return id
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Self.log.error("virtual display never appeared in the display list")
        destroy()
        return nil
    }

    /// Remove the display (releasing the `CGVirtualDisplay` does it).
    func destroy() {
        guard display != nil else { return }
        display = nil
        displayID = nil
        Self.log.info("virtual display released")
    }

    private static func activeDisplays() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count)))
    }
}
