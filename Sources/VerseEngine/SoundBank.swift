import Foundation
import AVFoundation

/// Locates the bundled GeneralUser GS SoundFont and the curated preset manifest.
///
/// The SF2 (~30 MB) is fetched by `scripts/fetch-artifacts.sh` into the module's Resources
/// and checksummed in THIRD-PARTY-LICENSES.md. It is intentionally *optional*: if absent,
/// `AVAudioUnitSampler` falls back to its built-in default voice so "hear sound" never blocks
/// (Build Contract §9).
public enum SoundBank {

    /// Logical bank name used in the model's `Instrument.sf2`.
    public static let generalUserGS = "GeneralUserGS"

    /// URL of the bundled GeneralUser GS SF2, or nil if it wasn't fetched/bundled.
    public static var generalUserGSURL: URL? {
        // Try a few resource names so either GeneralUserGS.sf2 or GeneralUser-GS.sf2 resolves.
        for name in ["GeneralUserGS", "GeneralUser-GS", "GeneralUser GS v2.0.3"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "sf2") { return url }
            if let url = Bundle.module.url(forResource: name, withExtension: "sf2",
                                           subdirectory: "Resources") { return url }
        }
        return nil
    }

    public static var isAvailable: Bool { generalUserGSURL != nil }

    // MARK: - Curated preset manifest

    public struct Preset: Codable, Hashable, Sendable {
        public let name: String        // plain-language label shown in the UI
        public let program: Int
        public let bankMSB: Int
        public let bankLSB: Int
        public let category: String    // e.g. "Keys", "Bass", "Guitar", "Pad", "Drums"
    }

    /// The curated, auditioned subset exposed in the default UI. Loaded from presets.json,
    /// with a hardcoded fallback list so the app always has instruments to offer.
    public static var presets: [Preset] {
        if let url = Bundle.module.url(forResource: "presets", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([Preset].self, from: data),
           !list.isEmpty {
            return list
        }
        return fallbackPresets
    }

    /// GM program numbers for a safe, broadly-correct subset (bank 121/0 melodic, 120/0 drums).
    static let fallbackPresets: [Preset] = [
        .init(name: "Grand Piano",     program: 0,  bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "Electric Piano",  program: 4,  bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "Clean Guitar",    program: 27, bankMSB: 121, bankLSB: 0, category: "Guitar"),
        .init(name: "Finger Bass",     program: 33, bankMSB: 121, bankLSB: 0, category: "Bass"),
        .init(name: "Warm Pad",        program: 89, bankMSB: 121, bankLSB: 0, category: "Pad"),
        .init(name: "Strings",         program: 48, bankMSB: 121, bankLSB: 0, category: "Strings"),
        .init(name: "Drum Kit",        program: 0,  bankMSB: 120, bankLSB: 0, category: "Drums"),
    ]
}
