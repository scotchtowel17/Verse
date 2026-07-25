import Foundation
import AVFoundation
import VerseModel

/// Locates the bundled GeneralUser GS SoundFont and the curated preset manifest.
///
/// The SF2 (~30 MB) is fetched by `scripts/fetch-artifacts.sh` / `scripts/make-app.sh` into
/// the module's Resources and checksummed in THIRD-PARTY-LICENSES.md. It is intentionally
/// *optional*: if absent, `AVAudioUnitSampler` falls back to its built-in default voice so
/// "hear sound" never blocks (Build Contract §9).
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

        public init(name: String, program: Int, bankMSB: Int, bankLSB: Int, category: String) {
            self.name = name
            self.program = program
            self.bankMSB = bankMSB
            self.bankLSB = bankLSB
            self.category = category
        }

        /// Stable picker identity: program + bank, not the display name.
        public var selectionKey: String {
            "\(program):\(bankMSB):\(bankLSB)"
        }

        public func matches(_ instrument: Instrument) -> Bool {
            program == instrument.program
                && bankMSB == instrument.bankMSB
                && bankLSB == instrument.bankLSB
        }
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

    /// Categories in first-appearance order from the curated list (for grouped pickers).
    public static var presetCategories: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for p in presets where seen.insert(p.category).inserted {
            order.append(p.category)
        }
        return order
    }

    public static func presets(in category: String) -> [Preset] {
        presets.filter { $0.category == category }
    }

    /// Curated preset matching program + bank, or nil when the instrument is off-list.
    public static func preset(matching instrument: Instrument) -> Preset? {
        presets.first { $0.matches(instrument) }
    }

    /// Picker selection key for an instrument (curated or custom).
    public static func selectionKey(for instrument: Instrument) -> String {
        "\(instrument.program):\(instrument.bankMSB):\(instrument.bankLSB)"
    }

    /// Honest label when program/bank is not in the curated list.
    public static func customLabel(for instrument: Instrument) -> String {
        "Custom (program \(instrument.program))"
    }

    /// Display name for the instrument: curated preset name, custom label, or fallback.
    public static func displayName(for instrument: Instrument?) -> String {
        guard let instrument else { return "Instrument" }
        if let p = preset(matching: instrument) { return p.name }
        return customLabel(for: instrument)
    }

    /// GM program numbers for a safe, broadly-correct subset (bank 121/0 melodic, 120/0 drums).
    /// Kept in sync with presets.json. Drum kits in bank 120 were load-verified against
    /// GeneralUser GS via AVAudioUnitSampler (see CheckEngine I1 suite).
    static let fallbackPresets: [Preset] = [
        .init(name: "Grand Piano",       program: 0,   bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "Bright Piano",      program: 1,   bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "Electric Grand",    program: 2,   bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "Electric Piano",    program: 4,   bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "DX Electric Piano", program: 5,   bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "Harpsichord",       program: 6,   bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "Clavinet",          program: 7,   bankMSB: 121, bankLSB: 0, category: "Keys"),
        .init(name: "Drawbar Organ",     program: 16,  bankMSB: 121, bankLSB: 0, category: "Organ"),
        .init(name: "Percussive Organ",  program: 17,  bankMSB: 121, bankLSB: 0, category: "Organ"),
        .init(name: "Rock Organ",        program: 18,  bankMSB: 121, bankLSB: 0, category: "Organ"),
        .init(name: "Church Organ",      program: 19,  bankMSB: 121, bankLSB: 0, category: "Organ"),
        .init(name: "Nylon Guitar",      program: 24,  bankMSB: 121, bankLSB: 0, category: "Guitar"),
        .init(name: "Steel Guitar",      program: 25,  bankMSB: 121, bankLSB: 0, category: "Guitar"),
        .init(name: "Jazz Guitar",       program: 26,  bankMSB: 121, bankLSB: 0, category: "Guitar"),
        .init(name: "Clean Guitar",      program: 27,  bankMSB: 121, bankLSB: 0, category: "Guitar"),
        .init(name: "Overdriven Guitar", program: 29,  bankMSB: 121, bankLSB: 0, category: "Guitar"),
        .init(name: "Distortion Guitar", program: 30,  bankMSB: 121, bankLSB: 0, category: "Guitar"),
        .init(name: "Acoustic Bass",     program: 32,  bankMSB: 121, bankLSB: 0, category: "Bass"),
        .init(name: "Finger Bass",       program: 33,  bankMSB: 121, bankLSB: 0, category: "Bass"),
        .init(name: "Pick Bass",         program: 34,  bankMSB: 121, bankLSB: 0, category: "Bass"),
        .init(name: "Fretless Bass",     program: 35,  bankMSB: 121, bankLSB: 0, category: "Bass"),
        .init(name: "Slap Bass",         program: 36,  bankMSB: 121, bankLSB: 0, category: "Bass"),
        .init(name: "Synth Bass",        program: 38,  bankMSB: 121, bankLSB: 0, category: "Bass"),
        .init(name: "Violin",            program: 40,  bankMSB: 121, bankLSB: 0, category: "Strings"),
        .init(name: "Cello",             program: 42,  bankMSB: 121, bankLSB: 0, category: "Strings"),
        .init(name: "Pizzicato Strings", program: 45,  bankMSB: 121, bankLSB: 0, category: "Strings"),
        .init(name: "Orchestral Harp",   program: 46,  bankMSB: 121, bankLSB: 0, category: "Strings"),
        .init(name: "Strings",           program: 48,  bankMSB: 121, bankLSB: 0, category: "Strings"),
        .init(name: "Synth Strings",     program: 50,  bankMSB: 121, bankLSB: 0, category: "Strings"),
        .init(name: "Choir Aahs",        program: 52,  bankMSB: 121, bankLSB: 0, category: "Strings"),
        .init(name: "Trumpet",           program: 56,  bankMSB: 121, bankLSB: 0, category: "Brass"),
        .init(name: "Trombone",          program: 57,  bankMSB: 121, bankLSB: 0, category: "Brass"),
        .init(name: "French Horn",       program: 60,  bankMSB: 121, bankLSB: 0, category: "Brass"),
        .init(name: "Brass Section",     program: 61,  bankMSB: 121, bankLSB: 0, category: "Brass"),
        .init(name: "Synth Brass",       program: 62,  bankMSB: 121, bankLSB: 0, category: "Brass"),
        .init(name: "Alto Sax",          program: 65,  bankMSB: 121, bankLSB: 0, category: "Woodwind"),
        .init(name: "Tenor Sax",         program: 66,  bankMSB: 121, bankLSB: 0, category: "Woodwind"),
        .init(name: "Oboe",              program: 68,  bankMSB: 121, bankLSB: 0, category: "Woodwind"),
        .init(name: "Clarinet",          program: 71,  bankMSB: 121, bankLSB: 0, category: "Woodwind"),
        .init(name: "Flute",             program: 73,  bankMSB: 121, bankLSB: 0, category: "Woodwind"),
        .init(name: "Pan Flute",         program: 75,  bankMSB: 121, bankLSB: 0, category: "Woodwind"),
        .init(name: "Square Lead",       program: 80,  bankMSB: 121, bankLSB: 0, category: "Synth Lead"),
        .init(name: "Saw Lead",          program: 81,  bankMSB: 121, bankLSB: 0, category: "Synth Lead"),
        .init(name: "Voice Lead",        program: 85,  bankMSB: 121, bankLSB: 0, category: "Synth Lead"),
        .init(name: "Fifths Lead",       program: 87,  bankMSB: 121, bankLSB: 0, category: "Synth Lead"),
        .init(name: "New Age Pad",       program: 88,  bankMSB: 121, bankLSB: 0, category: "Pad"),
        .init(name: "Warm Pad",          program: 89,  bankMSB: 121, bankLSB: 0, category: "Pad"),
        .init(name: "Choir Pad",         program: 91,  bankMSB: 121, bankLSB: 0, category: "Pad"),
        .init(name: "Halo Pad",          program: 94,  bankMSB: 121, bankLSB: 0, category: "Pad"),
        .init(name: "Sweep Pad",         program: 95,  bankMSB: 121, bankLSB: 0, category: "Pad"),
        .init(name: "Sitar",             program: 104, bankMSB: 121, bankLSB: 0, category: "Ethnic"),
        .init(name: "Banjo",             program: 105, bankMSB: 121, bankLSB: 0, category: "Ethnic"),
        .init(name: "Kalimba",           program: 108, bankMSB: 121, bankLSB: 0, category: "Ethnic"),
        .init(name: "Bagpipe",           program: 109, bankMSB: 121, bankLSB: 0, category: "Ethnic"),
        .init(name: "Vibraphone",        program: 11,  bankMSB: 121, bankLSB: 0, category: "Percussion"),
        .init(name: "Marimba",           program: 12,  bankMSB: 121, bankLSB: 0, category: "Percussion"),
        .init(name: "Tubular Bells",     program: 14,  bankMSB: 121, bankLSB: 0, category: "Percussion"),
        .init(name: "Steel Drums",       program: 114, bankMSB: 121, bankLSB: 0, category: "Percussion"),
        .init(name: "Seashore",          program: 122, bankMSB: 121, bankLSB: 0, category: "Sound Effects"),
        .init(name: "Telephone",         program: 124, bankMSB: 121, bankLSB: 0, category: "Sound Effects"),
        .init(name: "Applause",          program: 126, bankMSB: 121, bankLSB: 0, category: "Sound Effects"),
        .init(name: "Standard Kit",      program: 0,   bankMSB: 120, bankLSB: 0, category: "Drums"),
        .init(name: "Room Kit",          program: 8,   bankMSB: 120, bankLSB: 0, category: "Drums"),
        .init(name: "Power Kit",         program: 16,  bankMSB: 120, bankLSB: 0, category: "Drums"),
        .init(name: "Electronic Kit",    program: 24,  bankMSB: 120, bankLSB: 0, category: "Drums"),
        .init(name: "TR-808 Kit",        program: 25,  bankMSB: 120, bankLSB: 0, category: "Drums"),
        .init(name: "Jazz Kit",          program: 32,  bankMSB: 120, bankLSB: 0, category: "Drums"),
        .init(name: "Brush Kit",         program: 40,  bankMSB: 120, bankLSB: 0, category: "Drums"),
        .init(name: "Orchestra Kit",     program: 48,  bankMSB: 120, bankLSB: 0, category: "Drums"),
        .init(name: "SFX Kit",           program: 56,  bankMSB: 120, bankLSB: 0, category: "Drums"),
    ]
}
