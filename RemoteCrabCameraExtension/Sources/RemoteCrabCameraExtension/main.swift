import CoreMediaIO
import Foundation

// Entry point for the CMIO camera extension. The system launches this
// process when a client (Zoom, FaceTime, Photo Booth, …) enumerates or
// opens the "RemoteCrab Camera" device.
//
// `startService` only *registers* the provider; it returns. The process
// must then keep running or the system tears the extension down and the
// camera never appears in any app's device list. `CFRunLoopRun()` parks
// the main thread until the system terminates us.
let providerSource = CameraExtensionProvider()
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
