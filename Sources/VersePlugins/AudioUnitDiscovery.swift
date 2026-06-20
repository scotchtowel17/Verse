import Foundation
import AVFoundation
import AudioToolbox

/// Discovers Audio Units already installed on the system (Build Contract §8). MVP hosts only
/// installed AUs (AUv3 + in-process AUv2) discovered via `AVAudioUnitComponentManager`. No VST3,
/// no out-of-process host.
public struct DiscoveredAU: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let manufacturer: String
    public let kind: Kind
    public let componentDescription: AudioComponentDescription

    public enum Kind: String, Sendable { case effect, instrument }

    public static func == (l: DiscoveredAU, r: DiscoveredAU) -> Bool { l.id == r.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public enum AudioUnitDiscovery {

    public static func effects() -> [DiscoveredAU] {
        discover(type: kAudioUnitType_Effect, kind: .effect)
    }

    public static func instruments() -> [DiscoveredAU] {
        discover(type: kAudioUnitType_MusicDevice, kind: .instrument)
    }

    static func discover(type: OSType, kind: DiscoveredAU.Kind) -> [DiscoveredAU] {
        let desc = AudioComponentDescription(componentType: type, componentSubType: 0,
                                             componentManufacturer: 0, componentFlags: 0,
                                             componentFlagsMask: 0)
        let comps = AVAudioUnitComponentManager.shared().components(matching: desc)
        return comps.map { c in
            let cd = c.audioComponentDescription
            return DiscoveredAU(
                id: "\(c.manufacturerName).\(c.name).\(cd.componentSubType)",
                name: c.name,
                manufacturer: c.manufacturerName,
                kind: kind,
                componentDescription: cd)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
