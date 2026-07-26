import SwiftUI
import VerseModel

/// Display colours for the fixed 8-slot track identity palette (schema v3).
///
/// Chosen to stay legible and distinct in light and dark mode, and to remain
/// distinguishable under common colour-vision deficiencies (Okabe–Ito inspired;
/// no pure record-red). Semantic colours (record, playing accent, selection,
/// warning) must never be drawn from this palette.
public enum TrackIdentityColor {
    public struct Swatch: Sendable {
        public let name: String
        /// Solid identity colour for accent strips and solid chips.
        public let solid: Color
        /// Clip / note fill (softer than solid; not a large saturated block).
        public let fill: Color
        /// High-contrast label colour on `fill` and on solid chips in both appearances.
        public let label: Color
    }

    /// Eight fixed swatches, index-aligned with `Track.colorIndex`.
    public static let swatches: [Swatch] = [
        // 0 Sky blue
        Swatch(name: "Sky",
               solid: Color(red: 0.34, green: 0.71, blue: 0.91),
               fill: Color(red: 0.34, green: 0.71, blue: 0.91).opacity(0.55),
               label: Color(red: 0.06, green: 0.12, blue: 0.20)),
        // 1 Amber / orange (CVD-safe warm; not record red)
        Swatch(name: "Amber",
               solid: Color(red: 0.90, green: 0.62, blue: 0.00),
               fill: Color(red: 0.90, green: 0.62, blue: 0.00).opacity(0.55),
               label: Color(red: 0.18, green: 0.10, blue: 0.00)),
        // 2 Bluish green
        Swatch(name: "Teal",
               solid: Color(red: 0.00, green: 0.62, blue: 0.45),
               fill: Color(red: 0.00, green: 0.62, blue: 0.45).opacity(0.58),
               label: Color.white),
        // 3 Blue
        Swatch(name: "Blue",
               solid: Color(red: 0.00, green: 0.45, blue: 0.70),
               fill: Color(red: 0.00, green: 0.45, blue: 0.70).opacity(0.58),
               label: Color.white),
        // 4 Reddish purple
        Swatch(name: "Orchid",
               solid: Color(red: 0.80, green: 0.47, blue: 0.65),
               fill: Color(red: 0.80, green: 0.47, blue: 0.65).opacity(0.55),
               label: Color(red: 0.14, green: 0.06, blue: 0.12)),
        // 5 Yellow (dark label for contrast on light fill)
        Swatch(name: "Yellow",
               solid: Color(red: 0.94, green: 0.89, blue: 0.26),
               fill: Color(red: 0.94, green: 0.89, blue: 0.26).opacity(0.62),
               label: Color(red: 0.18, green: 0.16, blue: 0.02)),
        // 6 Burnt orange (distinct from pure record red)
        Swatch(name: "Rust",
               solid: Color(red: 0.84, green: 0.37, blue: 0.00),
               fill: Color(red: 0.84, green: 0.37, blue: 0.00).opacity(0.55),
               label: Color.white),
        // 7 Steel grey-blue
        Swatch(name: "Steel",
               solid: Color(red: 0.40, green: 0.46, blue: 0.55),
               fill: Color(red: 0.40, green: 0.46, blue: 0.55).opacity(0.55),
               label: Color.white),
    ]

    public static func swatch(for index: Int) -> Swatch {
        swatches[TrackPalette.normalized(index)]
    }

    public static func solid(for index: Int) -> Color { swatch(for: index).solid }
    public static func fill(for index: Int) -> Color { swatch(for: index).fill }
    public static func label(for index: Int) -> Color { swatch(for: index).label }
}
