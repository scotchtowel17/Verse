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

        // Metrics package is consistent. Height is from target key width (X5: no layout cycle).
        let width: CGFloat = 780
        let m = PianoKeyboardLayout.metrics(availableWidth: width)
        tk.expectEqual(m.octaves, PianoKeyboardLayout.octaveCount(availableWidth: width), "metrics.octaves")
        tk.expectEqual(m.whiteCount, PianoKeyboardLayout.whiteKeyCount(octaves: m.octaves), "metrics.whiteCount")
        tk.expect(abs(m.keyWidth - width / CGFloat(m.whiteCount)) < 0.001, "metrics fills width exactly")
        tk.expectEqual(m.height, PianoKeyboardLayout.fixedKeyboardHeight, "metrics.height from target, not fitted key")
        tk.expectEqual(
            m.height,
            PianoKeyboardLayout.keyboardHeight(whiteKeyWidth: target),
            "fixed height matches target key width"
        )
    }

    tk.suite("X4 PianoKeyboardLayout: fills available width exactly (no gap)") {
        for width: CGFloat in [200, 400, 640, 900, 1200, 1800] {
            let m = PianoKeyboardLayout.metrics(availableWidth: width)
            let filled = m.keyWidth * CGFloat(m.whiteCount)
            tk.expect(abs(filled - width) < 0.001, "fill \(filled) == width \(width)")
        }
    }

    // X5: collapse-to-min was the blank-keyboard bug (width stuck at 0 → min octaves).
    // A realistic window width must not clamp to the minimum.
    tk.suite("X5 realistic width yields more than one octave") {
        let realistic: CGFloat = 800
        let n = PianoKeyboardLayout.octaveCount(availableWidth: realistic)
        tk.expect(n > 1, "realistic width \(realistic) yields >1 octave (got \(n), min is \(minOct))")
        let m = PianoKeyboardLayout.metrics(availableWidth: realistic)
        tk.expect(m.octaves > 1, "metrics at \(realistic) also >1 octave")
        tk.expectEqual(m.height, PianoKeyboardLayout.fixedKeyboardHeight,
                       "height is constant (target-based), independent of width")
        // Zero width still clamps to min (pure function); UI draws nothing instead of a bar.
        tk.expectEqual(PianoKeyboardLayout.octaveCount(availableWidth: 0), minOct,
                       "zero width still pure-clamps to min; view guards and draws nothing")
    }

    // MARK: - Step Y1: every rendered key is MIDI-safe at every octave count and shift

    tk.suite("Y1 pitch span and base clamp for max octaves") {
        // The old default baseC=60 with 7 octaves put the top key at ~144 (silent after clamp).
        let n = maxOct
        let span = PianoKeyboardLayout.pitchSpan(octaves: n)
        tk.expectEqual(span, n * 12, "span is 12 per octave")
        let maxBase = PianoKeyboardLayout.maxBaseC(octaves: n)
        tk.expect(maxBase + span <= PianoKeyboardLayout.midiMaxPitch,
                  "max base \(maxBase) + span \(span) ≤ 127")
        let clamped60 = PianoKeyboardLayout.clampedBaseC(60, octaves: n)
        tk.expect(clamped60 <= maxBase, "default 60 clamps down for \(n) octaves (got \(clamped60))")
        tk.expect(clamped60 >= PianoKeyboardLayout.minBaseC(octaves: n), "clamped base ≥ 0")
        tk.expect(
            PianoKeyboardLayout.highestPitch(baseC: clamped60, octaves: n)
                <= PianoKeyboardLayout.midiMaxPitch,
            "highest pitch after clamp ≤ 127"
        )
        tk.expect(
            PianoKeyboardLayout.pitchesAreInMIDIRange(baseC: clamped60, octaves: n),
            "all keys for default-60 clamp are in 0...127"
        )
        // Without the clamp, the pre-Y1 layout was out of range.
        tk.expect(
            !PianoKeyboardLayout.pitchesAreInMIDIRange(baseC: 60, octaves: n),
            "raw base 60 at max octaves is still out of range (documents the bug)"
        )
    }

    tk.suite("Y1 every rendered key is in 0...127 at every octave count and shift") {
        let prefs = [-24, -1, 0, 12, 24, 36, 48, 60, 72, 84, 96, 108, 120, 127, 144, 200]
        var checkedKeys = 0
        var bad: String?
        for octaves in minOct...maxOct {
            for preferred in prefs {
                let base = PianoKeyboardLayout.clampedBaseC(preferred, octaves: octaves)
                if base < PianoKeyboardLayout.minBaseC(octaves: octaves)
                    || base > PianoKeyboardLayout.maxBaseC(octaves: octaves) {
                    bad = "clamped base \(base) out of range for \(octaves) oct (preferred \(preferred))"
                    break
                }
                let pitches = PianoKeyboardLayout.allPitches(baseC: base, octaves: octaves)
                if pitches.isEmpty {
                    bad = "no keys for \(octaves) oct at base \(base)"
                    break
                }
                for p in pitches {
                    checkedKeys += 1
                    if p < PianoKeyboardLayout.midiMinPitch || p > PianoKeyboardLayout.midiMaxPitch {
                        bad = "pitch \(p) outside 0...127 (base \(base), octaves \(octaves), preferred \(preferred))"
                        break
                    }
                }
                if bad != nil { break }
            }
            if bad != nil { break }
            // Every Z/X shift amount from several starts: must stay in range, never dead keys.
            for start in [0, 24, 36, 48, 60, 72, 96, 108, 120] {
                let origin = PianoKeyboardLayout.clampedBaseC(start, octaves: octaves)
                for delta in -20...20 {
                    let next = PianoKeyboardLayout.shiftedBaseC(origin, deltaOctaves: delta, octaves: octaves)
                    if next < PianoKeyboardLayout.minBaseC(octaves: octaves)
                        || next > PianoKeyboardLayout.maxBaseC(octaves: octaves) {
                        bad = "shift base \(next) out of range (start \(start), delta \(delta), oct \(octaves))"
                        break
                    }
                    for p in PianoKeyboardLayout.allPitches(baseC: next, octaves: octaves) {
                        checkedKeys += 1
                        if p < PianoKeyboardLayout.midiMinPitch || p > PianoKeyboardLayout.midiMaxPitch {
                            bad = "shifted pitch \(p) outside 0...127 (start \(start), delta \(delta), oct \(octaves))"
                            break
                        }
                    }
                    if bad != nil { break }
                }
                if bad != nil { break }
                // One-step walk: X stops at top, Z stops at bottom.
                var base = origin
                for _ in 0..<30 {
                    let up = PianoKeyboardLayout.shiftedBaseC(base, deltaOctaves: 1, octaves: octaves)
                    if up < base || up > PianoKeyboardLayout.maxBaseC(octaves: octaves) {
                        bad = "X walk invalid at octaves \(octaves) (base \(base) → \(up))"
                        break
                    }
                    if up == base { break }
                    base = up
                }
                if bad != nil { break }
                base = origin
                for _ in 0..<30 {
                    let down = PianoKeyboardLayout.shiftedBaseC(base, deltaOctaves: -1, octaves: octaves)
                    if down > base || down < PianoKeyboardLayout.minBaseC(octaves: octaves) {
                        bad = "Z walk invalid at octaves \(octaves) (base \(base) → \(down))"
                        break
                    }
                    if down == base { break }
                    base = down
                }
                if bad != nil { break }
            }
            if bad != nil { break }
        }
        tk.expect(bad == nil, bad ?? "all rendered keys in 0...127")
        tk.expect(checkedKeys > 0, "checked \(checkedKeys) rendered key pitches")
        // Octave count itself is capped so a left edge of 0 can never exceed 127.
        tk.expect(maxOct <= PianoKeyboardLayout.maxOctavesFittingMIDI,
                  "maxOctaves \(maxOct) ≤ MIDI-fitting cap \(PianoKeyboardLayout.maxOctavesFittingMIDI)")
        tk.expect(
            PianoKeyboardLayout.pitchesAreInMIDIRange(baseC: 0, octaves: maxOct),
            "from C0 at max octaves every key is in 0...127"
        )
    }

    tk.suite("Y1 shift is a no-op at the ends") {
        for octaves in minOct...maxOct {
            let top = PianoKeyboardLayout.maxBaseC(octaves: octaves)
            let bottom = PianoKeyboardLayout.minBaseC(octaves: octaves)
            tk.expectEqual(
                PianoKeyboardLayout.shiftedBaseC(top, deltaOctaves: 1, octaves: octaves),
                top,
                "X at top stays put (octaves \(octaves))"
            )
            tk.expectEqual(
                PianoKeyboardLayout.shiftedBaseC(bottom, deltaOctaves: -1, octaves: octaves),
                bottom,
                "Z at bottom stays put (octaves \(octaves))"
            )
        }
    }

    // MARK: - Musical ceiling (C8): base always a C, rendered keys never above 108

    tk.suite("musical ceiling: clampedBaseC is always a C and highest ≤ C8") {
        let prefs = [0, 24, 48, 60, 72, 127, -50, 500]
        let musicalMax = PianoKeyboardLayout.musicalMaxPitch
        for octaves in minOct...maxOct {
            for preferred in prefs {
                let base = PianoKeyboardLayout.clampedBaseC(preferred, octaves: octaves)
                tk.expect(base % 12 == 0,
                          "clampedBaseC(\(preferred), octaves:\(octaves)) is a C (got \(base))")
                tk.expect(base >= 0,
                          "clampedBaseC(\(preferred), octaves:\(octaves)) ≥ 0 (got \(base))")
                let high = PianoKeyboardLayout.highestPitch(baseC: base, octaves: octaves)
                tk.expect(high <= musicalMax,
                          "highestPitch for base \(base) octaves \(octaves) is \(high) ≤ \(musicalMax)")
            }
        }
    }

    tk.suite("musical ceiling: 7-octave span is C1...C8 (24...108)") {
        let n = 7
        tk.expectEqual(n, maxOct, "maxOctaves is 7 so this is the hard-cap case")
        // Preferred middle C (60) must not be discarded into a non-C; it clamps to the
        // highest C that still ends at C8.
        let base = PianoKeyboardLayout.clampedBaseC(60, octaves: n)
        let high = PianoKeyboardLayout.highestPitch(baseC: base, octaves: n)
        tk.expectEqual(base, 24,
                       "7-octave rendered span starts at C1 (24), not G (43) or raw 60 (got \(base))")
        tk.expectEqual(high, 108,
                       "7-octave rendered span ends at C8 (108), not G9 (127) (got \(high))")
        tk.expectEqual(PianoKeyboardLayout.maxBaseC(octaves: n), 24,
                       "maxBaseC(7) is C1 so the full span is C1...C8")
        tk.expect(
            base == 24 && high == 108,
            "7-octave rendered span is C1...C8 (24...108); got \(base)...\(high)"
        )
    }

    tk.suite("musical ceiling: shiftedBaseC never exceeds C8 or goes below 0") {
        let musicalMax = PianoKeyboardLayout.musicalMaxPitch
        for octaves in minOct...maxOct {
            for start in [0, 24, 48, 60, 72, 96, 108, 120, 127, -12, 500] {
                let origin = PianoKeyboardLayout.clampedBaseC(start, octaves: octaves)
                for delta in -10...10 {
                    let next = PianoKeyboardLayout.shiftedBaseC(origin, deltaOctaves: delta, octaves: octaves)
                    tk.expect(next >= 0,
                              "shiftedBaseC base \(next) ≥ 0 (start \(start), delta \(delta), oct \(octaves))")
                    let high = PianoKeyboardLayout.highestPitch(baseC: next, octaves: octaves)
                    tk.expect(high <= musicalMax,
                              "shifted highest \(high) ≤ \(musicalMax) (start \(start), delta \(delta), oct \(octaves))")
                    tk.expect(next % 12 == 0,
                              "shifted base \(next) is a C (start \(start), delta \(delta), oct \(octaves))")
                }
            }
        }
    }

    tk.suite("musical ceiling: white/black pitches are musical and white keys are real whites") {
        let musicalMax = PianoKeyboardLayout.musicalMaxPitch
        let whitePC: Set<Int> = [0, 2, 4, 5, 7, 9, 11]
        let prefs = [0, 24, 48, 60, 72, 127, -50, 500]
        for octaves in minOct...maxOct {
            let bases = Set(prefs.map { PianoKeyboardLayout.clampedBaseC($0, octaves: octaves) })
                .union([PianoKeyboardLayout.minBaseC(octaves: octaves),
                        PianoKeyboardLayout.maxBaseC(octaves: octaves)])
            for base in bases {
                let whites = PianoKeyboardLayout.whitePitches(baseC: base, octaves: octaves)
                let blacks = PianoKeyboardLayout.blackPitches(baseC: base, octaves: octaves)
                for p in whites {
                    tk.expect(p >= 0 && p <= musicalMax,
                              "white pitch \(p) in 0...\(musicalMax) (base \(base), oct \(octaves))")
                    tk.expect(whitePC.contains(p % 12),
                              "white pitch \(p) is a real white key (pc \(p % 12); base \(base), oct \(octaves))")
                }
                for p in blacks {
                    tk.expect(p >= 0 && p <= musicalMax,
                              "black pitch \(p) in 0...\(musicalMax) (base \(base), oct \(octaves))")
                }
            }
        }
    }
}
