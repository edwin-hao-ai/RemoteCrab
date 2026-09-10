import AudioToolbox
import AVFoundation
import Foundation
import iBridgeCore

/// AudioUnit v3 extension entry point. macOS discovers this when the
/// extension bundle is embedded in iBridgeReceiver.app/Contents/
/// PlugIns and registers it as a selectable audio input device.
///
/// **V0.2 status:** skeleton. The full AUv3 render pipeline is
/// scaffolded but the AU class itself is provided by the host (see
/// `iBridgeAUInstanceProvider` in iBridgeCore) so the extension and the
/// host can share the same buffer.
public final class iBridgeAudioFactory: NSObject, AUAudioUnitFactory {

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        // The real unit lives in the Mac app target — we just hand it
        // back here. The host process uses the same instance whether the
        // AU is being instantiated as a hosted extension or as an
        // in-process unit.
        let raw = iBridgeAUInstanceProvider.makeInstance
        guard let unit = raw as? AUAudioUnit else {
            throw NSError(domain: "iBridge.audio", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build AUAudioUnit"])
        }
        return unit
    }
}