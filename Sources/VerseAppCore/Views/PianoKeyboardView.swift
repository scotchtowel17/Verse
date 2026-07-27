import SwiftUI

// MARK: - Layout (testable)

/// Pure layout helpers for the on-screen piano. Free of SwiftUI so VerseCheck can lock
/// adaptive octave count, proportions, and MIDI-safe pitch ranges without rendering.
///
/// Keys fill the available width exactly for the chosen octave count, so white-key width
/// lands near `targetWhiteKeyWidth` instead of stretching two hard-coded octaves across
/// the whole window.
///
/// Pitch range (Y1): every rendered key must land in MIDI 0...127. The on-screen keyboard
/// further caps at C8 (`musicalMaxPitch` = 108), the top of an 88-key piano. The leftmost C
/// is derived from the preferred base and the octave count so the trailing C never exceeds
/// that musical ceiling and is always a real C. Z/X shift is clamped the same way so it
/// stops at the ends instead of producing dead or shrill keys.
public enum PianoKeyboardLayout {
    /// White-key width that reads correctly on screen (~real white keys are ~23mm).
    public static let targetWhiteKeyWidth: CGFloat = 26

    /// MIDI pitch floor / ceiling for note numbers (MIDI-validity clamp).
    public static let midiMinPitch = 0
    public static let midiMaxPitch = 127

    /// Musical ceiling for the rendered keyboard: C8, the top of an 88-key piano.
    /// MIDI allows up to 127, but anything above C8 is not musically useful (shrill or
    /// inaudible). Governs the rendered keyboard only; `midiMinPitch`/`midiMaxPitch`
    /// remain the MIDI-validity clamp.
    public static let musicalMaxPitch = 108

    /// Most octaves that fit when the left edge is C0 (pitch 0): floor(127/12).
    public static let maxOctavesFittingMIDI = midiMaxPitch / 12

    public static let minOctaves = 1
    /// Hard UI cap. Also never above what fits in MIDI from C0 (see `maxOctavesFittingMIDI`).
    public static let maxOctaves = min(7, maxOctavesFittingMIDI)

    /// White-key height as a multiple of white-key width (keeps short, fat keys from looking wrong).
    public static let whiteKeyHeightRatio: CGFloat = 5.0

    /// Floor so a very narrow window stays clickable.
    public static let minKeyboardHeight: CGFloat = 72

    /// Cap so a maxed-out wide window does not dominate the workspace.
    public static let maxKeyboardHeight: CGFloat = 160

    /// Semitone offsets of white keys within one octave (C D E F G A B).
    public static let whiteSemitones = [0, 2, 4, 5, 7, 9, 11]

    /// White-key indices (within an octave) that have a black key to their upper-right.
    public static let blackAfterWhite = [0, 1, 3, 4, 5]

    /// White keys for `octaves` spans, including the trailing C: 7n + 1.
    public static func whiteKeyCount(octaves: Int) -> Int {
        let n = max(0, octaves)
        return n * 7 + 1
    }

    /// Semitone span from the leftmost C to the trailing C (highest white key).
    public static func pitchSpan(octaves: Int) -> Int {
        max(0, octaves) * 12
    }

    /// Highest white-key pitch for a keyboard starting at `baseC` with `octaves` spans.
    public static func highestPitch(baseC: Int, octaves: Int) -> Int {
        baseC + pitchSpan(octaves: octaves)
    }

    /// Lowest allowed leftmost C (C0 / MIDI floor). Always a C (multiple of 12).
    public static func minBaseC(octaves: Int = 0) -> Int {
        _ = octaves
        return midiMinPitch
    }

    /// Highest allowed leftmost C so `baseC + octaves*12` stays ≤ `musicalMaxPitch` (C8),
    /// snapped down to a C (multiple of 12). Never negative. White/black layout assumes
    /// `baseC` is a C; returning a non-C (as the old MIDI-only formula did at 7 octaves)
    /// mislabels every key.
    public static func maxBaseC(octaves: Int) -> Int {
        let raw = musicalMaxPitch - pitchSpan(octaves: octaves)
        // Snap down to a C (multiple of 12). Integer division truncates toward zero;
        // for non-negative raw that is floor. Never return below the MIDI floor.
        let asC = (raw / 12) * 12
        return max(midiMinPitch, asC)
    }

    /// Clamp a preferred leftmost pitch so every key of an `octaves` keyboard stays within
    /// the musical render range, and so the result is always a C (multiple of 12).
    public static func clampedBaseC(_ preferred: Int, octaves: Int) -> Int {
        let lo = minBaseC(octaves: octaves)
        let hi = maxBaseC(octaves: octaves)
        // Floor preferred to a C before clamping (layout treats baseC as C).
        let preferredC = (preferred / 12) * 12
        return min(hi, max(lo, preferredC))
    }

    /// Z/X octave shift: move by `deltaOctaves` twelfths, then clamp for the rendered span.
    public static func shiftedBaseC(_ current: Int, deltaOctaves: Int, octaves: Int) -> Int {
        clampedBaseC(current + deltaOctaves * 12, octaves: octaves)
    }

    /// White-key MIDI pitches for a keyboard (includes trailing C).
    public static func whitePitches(baseC: Int, octaves: Int) -> [Int] {
        let count = whiteKeyCount(octaves: octaves)
        return (0..<count).map { i in
            baseC + (i / 7) * 12 + whiteSemitones[i % 7]
        }
    }

    /// Black-key MIDI pitches for a keyboard.
    public static func blackPitches(baseC: Int, octaves: Int) -> [Int] {
        var out: [Int] = []
        let n = max(0, octaves)
        for oct in 0..<n {
            for wi in blackAfterWhite {
                out.append(baseC + oct * 12 + whiteSemitones[wi] + 1)
            }
        }
        return out
    }

    /// Every pitch the on-screen keyboard would render (white + black).
    public static func allPitches(baseC: Int, octaves: Int) -> [Int] {
        whitePitches(baseC: baseC, octaves: octaves) + blackPitches(baseC: baseC, octaves: octaves)
    }

    /// True when every rendered key is inside MIDI 0...127.
    public static func pitchesAreInMIDIRange(baseC: Int, octaves: Int) -> Bool {
        allPitches(baseC: baseC, octaves: octaves).allSatisfy { $0 >= midiMinPitch && $0 <= midiMaxPitch }
    }

    /// Octave span that best matches `availableWidth` at `targetWhiteKeyWidth`, clamped to
    /// `minOctaves`...`maxOctaves` and never above what can fit in MIDI 0...127.
    /// Pure and side-effect free.
    public static func octaveCount(
        availableWidth: CGFloat,
        targetWhiteKeyWidth: CGFloat = targetWhiteKeyWidth,
        minOctaves: Int = minOctaves,
        maxOctaves: Int = maxOctaves
    ) -> Int {
        let lo = max(1, min(minOctaves, maxOctaves))
        // Cap by MIDI width from C0 as well as the caller's max.
        let hi = min(max(lo, max(minOctaves, maxOctaves)), maxOctavesFittingMIDI)
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
///
/// `preferredBaseC` is the user's Z/X preference. The left edge actually drawn is
/// `clampedBaseC(preferredBaseC, octaves:)` so the whole span stays inside the musical
/// render range (C0...C8) and every key stays inside MIDI 0...127.
struct PianoKeyboardView: View {
    /// Preferred MIDI pitch of the leftmost C (before range clamp).
    let preferredBaseC: Int
    let held: Set<Int>
    var noteOn: (Int) -> Void
    var noteOff: (Int) -> Void
    /// Reports the live octave count so Z/X shift can clamp against the same span.
    var onOctavesChanged: ((Int) -> Void)? = nil

    var body: some View {
        let height = PianoKeyboardLayout.fixedKeyboardHeight
        GeometryReader { geo in
            let width = geo.size.width
            // Degenerate first pass: width not yet known. Draw nothing; next pass fills in.
            if width > 0 {
                let m = PianoKeyboardLayout.metrics(availableWidth: width)
                let baseC = PianoKeyboardLayout.clampedBaseC(preferredBaseC, octaves: m.octaves)
                let whites = PianoKeyboardLayout.whitePitches(baseC: baseC, octaves: m.octaves)
                ZStack(alignment: .topLeading) {
                    // White keys
                    HStack(spacing: 0) {
                        ForEach(Array(whites.enumerated()), id: \.offset) { _, pitch in
                            PianoKey(isBlack: false, isHeld: held.contains(pitch),
                                     onPress: { noteOn(pitch) }, onRelease: { noteOff(pitch) })
                                .frame(width: m.keyWidth, height: height)
                        }
                    }
                    // Black keys overlaid
                    ForEach(blackKeyItems(baseC: baseC, octaves: m.octaves), id: \.pitch) { item in
                        PianoKey(isBlack: true, isHeld: held.contains(item.pitch),
                                 onPress: { noteOn(item.pitch) }, onRelease: { noteOff(item.pitch) })
                            .frame(width: m.keyWidth * 0.62, height: height * 0.62)
                            .offset(x: CGFloat(item.whiteIndex + 1) * m.keyWidth - (m.keyWidth * 0.31), y: 0)
                    }
                }
                .onAppear { onOctavesChanged?(m.octaves) }
                .onChange(of: m.octaves) { _, n in onOctavesChanged?(n) }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.15)))
    }

    private func blackKeyItems(baseC: Int, octaves: Int) -> [(pitch: Int, whiteIndex: Int)] {
        var out: [(pitch: Int, whiteIndex: Int)] = []
        let n = max(0, octaves)
        for oct in 0..<n {
            for wi in PianoKeyboardLayout.blackAfterWhite {
                let whiteIndex = oct * 7 + wi
                let pitch = baseC + oct * 12 + PianoKeyboardLayout.whiteSemitones[wi] + 1
                out.append((pitch: pitch, whiteIndex: whiteIndex))
            }
        }
        return out
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
