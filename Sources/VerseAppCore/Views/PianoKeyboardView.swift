import SwiftUI

// MARK: - Layout (testable)

/// Pure layout helpers for the on-screen piano. Free of SwiftUI so VerseCheck can lock
/// adaptive octave count and proportions without rendering.
///
/// Keys fill the available width exactly for the chosen octave count, so white-key width
/// lands near `targetWhiteKeyWidth` instead of stretching two hard-coded octaves across
/// the whole window.
public enum PianoKeyboardLayout {
    /// White-key width that reads correctly on screen (~real white keys are ~23mm).
    public static let targetWhiteKeyWidth: CGFloat = 26

    public static let minOctaves = 1
    public static let maxOctaves = 7

    /// White-key height as a multiple of white-key width (keeps short, fat keys from looking wrong).
    public static let whiteKeyHeightRatio: CGFloat = 5.0

    /// Floor so a very narrow window stays clickable.
    public static let minKeyboardHeight: CGFloat = 72

    /// Cap so a maxed-out wide window does not dominate the workspace.
    public static let maxKeyboardHeight: CGFloat = 160

    /// White keys for `octaves` spans, including the trailing C: 7n + 1.
    public static func whiteKeyCount(octaves: Int) -> Int {
        let n = max(0, octaves)
        return n * 7 + 1
    }

    /// Octave span that best matches `availableWidth` at `targetWhiteKeyWidth`, clamped to
    /// `minOctaves`...`maxOctaves`. Pure and side-effect free.
    public static func octaveCount(
        availableWidth: CGFloat,
        targetWhiteKeyWidth: CGFloat = targetWhiteKeyWidth,
        minOctaves: Int = minOctaves,
        maxOctaves: Int = maxOctaves
    ) -> Int {
        let lo = max(1, min(minOctaves, maxOctaves))
        let hi = max(lo, max(minOctaves, maxOctaves))
        let target = max(targetWhiteKeyWidth, 1)
        let width = max(availableWidth, 0)
        // whiteCount = 7n + 1; choose n so count * target ≈ width.
        let idealWhiteKeys = width / target
        let raw = Int((idealWhiteKeys - 1) / 7.0 + 0.5) // round half up via +0.5 then truncate
        return min(hi, max(lo, raw))
    }

    /// Exact white-key width when `octaves` fill `availableWidth` with no gaps.
    public static func whiteKeyWidth(availableWidth: CGFloat, octaves: Int) -> CGFloat {
        let count = max(1, whiteKeyCount(octaves: octaves))
        return max(availableWidth, 0) / CGFloat(count)
    }

    /// Keyboard height from white-key width (clamped for extreme sizes).
    public static func keyboardHeight(
        whiteKeyWidth: CGFloat,
        heightRatio: CGFloat = whiteKeyHeightRatio,
        minHeight: CGFloat = minKeyboardHeight,
        maxHeight: CGFloat = maxKeyboardHeight
    ) -> CGFloat {
        let raw = max(whiteKeyWidth, 1) * max(heightRatio, 0.1)
        let lo = min(minHeight, maxHeight)
        let hi = max(minHeight, maxHeight)
        return min(hi, max(lo, raw))
    }

    /// Height used by the on-screen keyboard: from the constant target key width only.
    /// Must not depend on measured container width (that would reintroduce a layout cycle).
    public static var fixedKeyboardHeight: CGFloat {
        keyboardHeight(whiteKeyWidth: targetWhiteKeyWidth)
    }

    /// Full metrics for a given width: octave count, white count, key size, height.
    /// Height is from the target key width (constant), not the fitted key width, so UI layout
    /// never depends on measured width for its vertical size.
    public static func metrics(availableWidth: CGFloat) -> (
        octaves: Int,
        whiteCount: Int,
        keyWidth: CGFloat,
        height: CGFloat
    ) {
        let octaves = octaveCount(availableWidth: availableWidth)
        let whiteCount = whiteKeyCount(octaves: octaves)
        let keyWidth = whiteKeyWidth(availableWidth: availableWidth, octaves: octaves)
        let height = fixedKeyboardHeight
        return (octaves, whiteCount, keyWidth, height)
    }
}

// MARK: - View

/// An on-screen piano. Click/hold a key to play; held notes (from mouse OR computer keyboard
/// or MIDI) are highlighted. Octave count adapts to available width so keys stay near a
/// natural width instead of stretching two hard-coded octaves across the window.
///
/// Layout: `GeometryReader` is the container. Octave count comes from `geo.size.width`
/// directly (no preference round-trip). Height is a constant from `targetWhiteKeyWidth`,
/// so it never depends on measured width and cannot form a layout cycle.
struct PianoKeyboardView: View {
    let baseC: Int                 // MIDI pitch of the leftmost C
    let held: Set<Int>
    var noteOn: (Int) -> Void
    var noteOff: (Int) -> Void

    private static let whiteSemis = [0, 2, 4, 5, 7, 9, 11]
    // White-key indices (within an octave) that have a black key to their upper-right.
    private static let blackAfter = [0, 1, 3, 4, 5]

    var body: some View {
        let height = PianoKeyboardLayout.fixedKeyboardHeight
        GeometryReader { geo in
            let width = geo.size.width
            // Degenerate first pass: width not yet known. Draw nothing; next pass fills in.
            if width > 0 {
                let m = PianoKeyboardLayout.metrics(availableWidth: width)
                ZStack(alignment: .topLeading) {
                    // White keys
                    HStack(spacing: 0) {
                        ForEach(0..<m.whiteCount, id: \.self) { i in
                            let pitch = whitePitch(i)
                            PianoKey(isBlack: false, isHeld: held.contains(pitch),
                                     onPress: { noteOn(pitch) }, onRelease: { noteOff(pitch) })
                                .frame(width: m.keyWidth, height: height)
                        }
                    }
                    // Black keys overlaid
                    ForEach(blackPitches(octaves: m.octaves), id: \.pitch) { item in
                        PianoKey(isBlack: true, isHeld: held.contains(item.pitch),
                                 onPress: { noteOn(item.pitch) }, onRelease: { noteOff(item.pitch) })
                            .frame(width: m.keyWidth * 0.62, height: height * 0.62)
                            .offset(x: CGFloat(item.whiteIndex + 1) * m.keyWidth - (m.keyWidth * 0.31), y: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.15)))
    }

    private func whitePitch(_ i: Int) -> Int {
        // Trailing C is the first white key of the next octave (i / 7 * 12 + C).
        baseC + (i / 7) * 12 + Self.whiteSemis[i % 7]
    }

    private func blackPitches(octaves: Int) -> [(pitch: Int, whiteIndex: Int)] {
        var out: [(Int, Int)] = []
        for oct in 0..<octaves {
            for wi in Self.blackAfter {
                let whiteIndex = oct * 7 + wi
                let pitch = baseC + oct * 12 + Self.whiteSemis[wi] + 1
                out.append((pitch, whiteIndex))
            }
        }
        return out.map { (pitch: $0.0, whiteIndex: $0.1) }
    }
}

private struct PianoKey: View {
    let isBlack: Bool
    let isHeld: Bool
    var onPress: () -> Void
    var onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        let base: Color = isBlack ? .black : .white
        let highlight: Color = isBlack ? Color(red: 0.30, green: 0.55, blue: 1.0)
                                       : Color(red: 0.70, green: 0.82, blue: 1.0)
        RoundedRectangle(cornerRadius: isBlack ? 3 : 4)
            .fill(isHeld ? highlight : base)
            .overlay(RoundedRectangle(cornerRadius: isBlack ? 3 : 4)
                .strokeBorder(.black.opacity(isBlack ? 0.0 : 0.25), lineWidth: 0.5))
            .shadow(color: isBlack ? .black.opacity(0.4) : .clear, radius: isBlack ? 2 : 0, y: 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; onPress() } }
                    .onEnded { _ in pressed = false; onRelease() }
            )
    }
}
