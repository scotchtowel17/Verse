import Foundation

/// Snap and quantize grid divisions in beats (Step Z2).
///
/// One beat is a quarter note. Straight values are note fractions of that beat;
/// triplet values are one third of the corresponding straight division:
/// 1/4T = 1/3 beat, 1/8T = 1/6 beat, 1/16T = 1/12 beat.
///
/// Used by arrangement snap, piano-roll snap, quantize, and the AI `quantizeNotes` op.
public enum SnapGrid {
    /// Free placement; quantize is disabled.
    public static let off: Double = 0
    /// Quarter note = 1 beat.
    public static let quarter: Double = 1.0
    /// Eighth note = 1/2 beat.
    public static let eighth: Double = 0.5
    /// Sixteenth note = 1/4 beat.
    public static let sixteenth: Double = 0.25
    /// Thirty-second note = 1/8 beat.
    public static let thirtySecond: Double = 0.125
    /// Quarter-note triplet = one third of a beat.
    public static let quarterTriplet: Double = 1.0 / 3.0
    /// Eighth-note triplet = one sixth of a beat.
    public static let eighthTriplet: Double = 1.0 / 6.0
    /// Sixteenth-note triplet = one twelfth of a beat.
    public static let sixteenthTriplet: Double = 1.0 / 12.0

    /// Grids that quantize (and the AI op) accept. Does not include Off.
    public static let allowedQuantizeGrids: Set<Double> = [
        quarter, eighth, sixteenth, thirtySecond,
        quarterTriplet, eighthTriplet, sixteenthTriplet,
    ]

    /// Compact labels for pickers and status text, keyed by beats value.
    /// Order: Off, straight (coarse → fine), then triplets (coarse → fine).
    public static let pickerOptions: [(label: String, beats: Double)] = [
        ("Off", off),
        ("1/4", quarter),
        ("1/8", eighth),
        ("1/16", sixteenth),
        ("1/32", thirtySecond),
        ("1/4T", quarterTriplet),
        ("1/8T", eighthTriplet),
        ("1/16T", sixteenthTriplet),
    ]

    public static func isAllowedQuantizeGrid(_ beats: Double) -> Bool {
        allowedQuantizeGrids.contains(beats)
    }

    /// Short label for the snap control (e.g. "1/16", "1/8T"). Unknown values fall back to a number.
    public static func shortLabel(for beats: Double) -> String {
        if let match = pickerOptions.first(where: { $0.beats == beats }) {
            return match.label
        }
        return String(beats)
    }

    /// Longer label for previews and help (e.g. "1/16 note", "1/8T triplet").
    public static func displayLabel(for beats: Double) -> String {
        switch beats {
        case off: return "Off"
        case quarter: return "1/4 note"
        case eighth: return "1/8 note"
        case sixteenth: return "1/16 note"
        case thirtySecond: return "1/32 note"
        case quarterTriplet: return "1/4T triplet"
        case eighthTriplet: return "1/8T triplet"
        case sixteenthTriplet: return "1/16T triplet"
        default: return "\(beats)-beat grid"
        }
    }

    /// Parse a numeric or string grid from a patch op. Returns nil when unsupported.
    public static func parseGrid(_ value: Double) -> Double? {
        isAllowedQuantizeGrid(value) ? value : nil
    }

    /// Parse labels such as "1/16", "1/8T", "0.25". Returns nil when unsupported.
    public static func parseGridLabel(_ raw: String) -> Double? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1/4", "1": return quarter
        case "1/8", "0.5": return eighth
        case "1/16", "0.25": return sixteenth
        case "1/32", "0.125": return thirtySecond
        case "1/4T", "1/3": return quarterTriplet
        case "1/8T", "1/6": return eighthTriplet
        case "1/16T", "1/12": return sixteenthTriplet
        default: return nil
        }
    }

    /// User-facing quantize refusal when snap is Off or an unknown grid is selected.
    public static let quantizeNeedsSnapMessage =
        "Turn on snap (1/4–1/32 or triplets) to quantize"
}
