import Foundation
import CoreGraphics
import VerseAppCore

// MARK: - Step X4: adaptive on-screen keyboard layout

/// Locks the pure `PianoKeyboardLayout` helpers: octave count from width vs target white-key
/// width, clamps, key-width band, and height proportional to key width.
func runPianoKeyboardLayoutChecks(_ tk: TestKit) {
    let target = PianoKeyboardLayout.targetWhiteKeyWidth
    let minOct = PianoKeyboardLayout.minOctaves
    let maxOct = PianoKeyboardLayout.maxOctaves

    tk.suite("X4 PianoKeyboardLayout: whiteKeyCount is 7n + 1") {
        tk.expectEqual(PianoKeyboardLayout.whiteKeyCount(octaves: 1), 8, "1 octave → 8 whites")
        tk.expectEqual(PianoKeyboardLayout.whiteKeyCount(octaves: 2), 15, "2 octaves → 15 whites")
        tk.expectEqual(PianoKeyboardLayout.whiteKeyCount(octaves: 7), 50, "7 octaves → 50 whites")
        tk.expectEqual(PianoKeyboardLayout.whiteKeyCount(octaves: 0), 1, "0 octaves → trailing C only")
    }

    tk.suite("X4 PianoKeyboardLayout: narrow width yields minimum octaves") {
        let n0 = PianoKeyboardLayout.octaveCount(availableWidth: 0)
        let nTiny = PianoKeyboardLayout.octaveCount(availableWidth: 40)
        let nOne = PianoKeyboardLayout.octaveCount(availableWidth: CGFloat(PianoKeyboardLayout.whiteKeyCount(octaves: 1)) * target)
        tk.expectEqual(n0, minOct, "zero width clamps to min")
        tk.expectEqual(nTiny, minOct, "tiny width clamps to min")
        tk.expectEqual(nOne, minOct, "exact 1-octave target width → min")
        tk.expect(n0 >= minOct && n0 <= maxOct, "zero width in clamp range")
    }

    tk.suite("X4 PianoKeyboardLayout: wide width yields more octaves, not wider keys only") {
        // Two hard-coded octaves at a typical window (~900pt) produced ~60pt keys.
        // Adaptive layout should pick more than 2 octaves so keys stay near the target.
        let wide: CGFloat = 900
        let n = PianoKeyboardLayout.octaveCount(availableWidth: wide)
        tk.expect(n > 2, "wide window uses more than 2 octaves (got \(n))")
        let keyW = PianoKeyboardLayout.whiteKeyWidth(availableWidth: wide, octaves: n)
        let fixedTwoW = wide / CGFloat(PianoKeyboardLayout.whiteKeyCount(octaves: 2))
        tk.expect(keyW < fixedTwoW, "adaptive key width under fixed-2-octave stretch (\(keyW) < \(fixedTwoW))")
        tk.expect(abs(keyW - target) < abs(fixedTwoW - target),
                  "adaptive closer to target than fixed 2 octaves")
    }

    tk.suite("X4 PianoKeyboardLayout: clamp holds at both ends") {
        let huge: CGFloat = 50_000
        let nHuge = PianoKeyboardLayout.octaveCount(availableWidth: huge)
        tk.expectEqual(nHuge, maxOct, "absurd width clamps to max octaves")

        // Explicit min/max override still clamps.
        let n = PianoKeyboardLayout.octaveCount(
            availableWidth: 10_000,
            targetWhiteKeyWidth: target,
            minOctaves: 2,
            maxOctaves: 4
        )
        tk.expectEqual(n, 4, "custom maxOctaves clamp")
        let n2 = PianoKeyboardLayout.octaveCount(
            availableWidth: 10,
            targetWhiteKeyWidth: target,
            minOctaves: 2,
            maxOctaves: 4
        )
        tk.expectEqual(n2, 2, "custom minOctaves clamp")
    }

    tk.suite("X4 PianoKeyboardLayout: key width stays in a sane band across widths") {
        // Unclamped band: enough width for min octaves at target through max at target.
        let minW = CGFloat(PianoKeyboardLayout.whiteKeyCount(octaves: minOct)) * target
        let maxW = CGFloat(PianoKeyboardLayout.whiteKeyCount(octaves: maxOct)) * target
        var worstLow: CGFloat = .greatestFiniteMagnitude
        var worstHigh: CGFloat = 0
        let samples: [CGFloat] = stride(from: Double(minW), through: Double(maxW), by: 20).map { CGFloat($0) }
        for width in samples {
            let n = PianoKeyboardLayout.octaveCount(availableWidth: width)
            let keyW = PianoKeyboardLayout.whiteKeyWidth(availableWidth: width, octaves: n)
            worstLow = min(worstLow, keyW)
            worstHigh = max(worstHigh, keyW)
            // Near the target: rounding boundaries can push a bit under/over.
            tk.expect(keyW >= target * 0.55 && keyW <= target * 1.55,
                      "key width \(keyW) in band at width \(width) (octaves \(n))")
        }
        tk.expect(worstLow >= target * 0.55, "lowest sample key width \(worstLow)")
        tk.expect(worstHigh <= target * 1.55, "highest sample key width \(worstHigh)")
    }

    tk.suite("X4 PianoKeyboardLayout: octave count is monotonic non-decreasing with width") {
        var prev = 0
        for w in stride(from: 0.0, through: 3000.0, by: 15.0) {
            let n = PianoKeyboardLayout.octaveCount(availableWidth: CGFloat(w))
            tk.expect(n >= prev, "octaves at \(w) (\(n)) >= previous \(prev)")
            prev = n
        }
    }

    tk.suite("X4 PianoKeyboardLayout: height tracks key width (clamped)") {
        let ratio = PianoKeyboardLayout.whiteKeyHeightRatio
        let minH = PianoKeyboardLayout.minKeyboardHeight
        let maxH = PianoKeyboardLayout.maxKeyboardHeight

        // Mid-band key width → pure proportion, within clamps.
        let midKey: CGFloat = 26
        let hMid = PianoKeyboardLayout.keyboardHeight(whiteKeyWidth: midKey)
        tk.expectEqual(hMid, midKey * ratio, "mid key uses ratio \(ratio)")
        tk.expect(hMid >= minH && hMid <= maxH, "mid height inside clamps")

        // Very thin keys → floor.
        let hThin = PianoKeyboardLayout.keyboardHeight(whiteKeyWidth: 8)
        tk.expectEqual(hThin, minH, "thin keys hit min height")

        // Very fat keys → cap.
        let hFat = PianoKeyboardLayout.keyboardHeight(whiteKeyWidth: 80)
        tk.expectEqual(hFat, maxH, "fat keys hit max height")

        // Metrics package is consistent.
        let width: CGFloat = 780
        let m = PianoKeyboardLayout.metrics(availableWidth: width)
        tk.expectEqual(m.octaves, PianoKeyboardLayout.octaveCount(availableWidth: width), "metrics.octaves")
        tk.expectEqual(m.whiteCount, PianoKeyboardLayout.whiteKeyCount(octaves: m.octaves), "metrics.whiteCount")
        tk.expect(abs(m.keyWidth - width / CGFloat(m.whiteCount)) < 0.001, "metrics fills width exactly")
        tk.expectEqual(m.height, PianoKeyboardLayout.keyboardHeight(whiteKeyWidth: m.keyWidth), "metrics.height")
    }

    tk.suite("X4 PianoKeyboardLayout: fills available width exactly (no gap)") {
        for width: CGFloat in [200, 400, 640, 900, 1200, 1800] {
            let m = PianoKeyboardLayout.metrics(availableWidth: width)
            let filled = m.keyWidth * CGFloat(m.whiteCount)
            tk.expect(abs(filled - width) < 0.001, "fill \(filled) == width \(width)")
        }
    }
}
