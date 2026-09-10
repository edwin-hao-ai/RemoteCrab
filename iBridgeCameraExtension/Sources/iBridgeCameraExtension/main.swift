import CoreMediaIO
import Foundation

// Entry point for the CMIO camera extension. The system launches this
// process when a client (Zoom, FaceTime, Photo Booth, …) enumerates or
// opens the "iBridge Camera" device. `startService` never returns.
let providerSource = CameraExtensionProvider()
CMIOExtensionProvider.startService(provider: providerSource.provider)
