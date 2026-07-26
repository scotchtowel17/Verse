import Foundation
import CoreGraphics
import VerseModel
import VerseAppCore

// MARK: - Step V5: property-test pure layout, selection, and split

/// Seeded property tests for pure, headless helpers that used to be view-only:
/// `PianoRollLayout.visiblePitchRange`, `Project.splitClip`, note/clip group move,
/// marquee hit-testing (including degenerate marquees), and `BeatTimeline` beat↔x.
///
/// Failures are reported, not silent-fixed. Uses `SeededRNG` so a failing trial reproduces.
func runLayoutSelectionPropertyChecks(_ tk: TestKit) {
    runVisiblePitchRangeProperty(tk)
    runSplitProperty(tk)
    runGroupMoveProperty(tk)
    runMarqueeProperty(tk)
    runBeatToXProperty(tk)
}

// MARK: - 1. visiblePitchRange

private func runVisiblePitchRangeProperty(_ tk: TestKit) {
    let seed: UInt64 = 0xA515_0001
    let trials = 200
    let rowH = PianoRollLayout.rowHeight

    tk.suite("V5 visiblePitchRange property (seed 0xA5150001, \(trials) trials)") {
        var rng = SeededRNG(seed: seed)
        var failures = 0
        var first: String?

        for trial in 0..<trials {
            let focus = rng.nextInt(in: -20...150)
            // Pane heights from zero through more than the full MIDI keyboard.
            let paneRows = rng.nextDouble(in: 0...200)
            let paneHeight = CGFloat(paneRows) * rowH + CGFloat(rng.nextDouble(in: 0...(Double(rowH) - 0.01)))
            // Sometimes use non-default row height (still positive).
            let rh: CGFloat = rng.nextBool()
                ? rowH
                : CGFloat(rng.nextDouble(in: 1...40))

            let range = PianoRollLayout.visiblePitchRange(
                focusPitch: focus, paneHeight: paneHeight, rowHeight: rh)

            let safeRH = max(rh, 1)
            let requestedRows = max(1, Int(floor(paneHeight / safeRH)))
            let count = range.upperBound - range.lowerBound + 1
            let clampedFocus = min(127, max(0, focus))

            // Never leaves 0…127.
            if range.lowerBound < 0 || range.upperBound > 127 {
                failures += 1
                first = first ?? "trial \(trial): range \(range) left 0…127"
                continue
            }
            if range.lowerBound > range.upperBound {
                failures += 1
                first = first ?? "trial \(trial): inverted range \(range)"
                continue
            }

            // Always contains the (clamped) focus pitch.
            if !range.contains(clampedFocus) {
                failures += 1
                first = first ?? "trial \(trial): range \(range) missing focus \(clampedFocus) (raw \(focus))"
                continue
            }

            // Row count matches what the pane can show, capped at the full keyboard (128).
            let expectedCount = min(requestedRows, 128)
            if count != expectedCount {
                failures += 1
                first = first ?? "trial \(trial): row count \(count) != expected \(expectedCount) (requested \(requestedRows), pane \(paneHeight), rh \(rh))"
                continue
            }

            // When clamped at either end and the keyboard is larger than the pane, the
            // window shifts rather than shrinks: count stays at requestedRows.
            if requestedRows <= 128 && count != requestedRows {
                failures += 1
                first = first ?? "trial \(trial): should shift not shrink; count \(count) vs \(requestedRows)"
                continue
            }
        }

        // Fixed edge cases outside the random cloud.
        let edges: [(focus: Int, pane: CGFloat, rh: CGFloat, label: String)] = [
            (0, rowH * 24, rowH, "focus at floor"),
            (127, rowH * 24, rowH, "focus at ceiling"),
            (60, 0, rowH, "zero pane height"),
            (60, rowH * 0.5, rowH, "sub-row pane height"),
            (60, rowH * 200, rowH, "taller than full keyboard"),
            (-5, rowH * 12, rowH, "focus below MIDI"),
            (200, rowH * 12, rowH, "focus above MIDI"),
        ]
        for e in edges {
            let r = PianoRollLayout.visiblePitchRange(
                focusPitch: e.focus, paneHeight: e.pane, rowHeight: e.rh)
            let cf = min(127, max(0, e.focus))
            if r.lowerBound < 0 || r.upperBound > 127 || !r.contains(cf) {
                failures += 1
                first = first ?? "edge \(e.label): bad range \(r) for focus \(e.focus)"
            }
        }

        tk.expect(failures == 0, "visiblePitchRange invariants hold",
                  first ?? "all \(trials) trials + edges ok")
        tk.expectEqual(failures, 0, "visiblePitchRange failure count is zero")
    }
}

// MARK: - 2. Split

private func runSplitProperty(_ tk: TestKit) {
    let seed: UInt64 = 0xA515_0002
    let trials = 120

    tk.suite("V5 split property (seed 0xA5150002, \(trials) trials)") {
        var rng = SeededRNG(seed: seed)
        var failures = 0
        var first: String?

        for trial in 0..<trials {
            let clipStart = rng.nextDouble(in: 0...32)
            let clipLen = rng.nextDouble(in: 0.5...16)
            let noteCount = rng.nextInt(in: 0...12)
            var notes: [Note] = []
            notes.reserveCapacity(noteCount)
            for _ in 0..<noteCount {
                // Local starts may sit past the clip end (real projects can have that);
                // split still partitions by the local boundary.
                let start = rng.nextDouble(in: 0...max(clipLen * 1.25, 0.25))
                let len = rng.nextDouble(in: 0.0625...4)
                notes.append(Note(
                    id: rng.nextUUID(),
                    startBeat: start,
                    lengthBeats: len,
                    pitch: rng.nextInt(in: 0...127),
                    velocity: rng.nextInt(in: 1...127)
                ))
            }

            let clip = Clip(
                id: rng.nextUUID(),
                kind: .midi,
                name: "V5-\(trial)",
                startBeat: clipStart,
                lengthBeats: clipLen,
                midiNotes: notes
            )

            // Interior split point in arrangement-absolute beats (strictly inside).
            // Avoid the exact endpoints; use a fraction in (0,1).
            let fraction = rng.nextDouble(in: 0.001...0.999)
            let playhead = clipStart + fraction * clipLen
            let local = playhead - clipStart
            // Guard against floating noise landing on an endpoint.
            if !(local > 0 && local < clipLen) {
                continue
            }

            let origTotalDuration = notes.map(\.lengthBeats).reduce(0, +)
            let crossingCount = notes.filter { n in
                let end = n.startBeat + n.lengthBeats
                return n.startBeat < local && end > local
            }.count
            let expectedNoteCount = notes.count + crossingCount

            var project = Project.newUntitled()
            project.tracks[0].clips = [clip]

            let pair: (left: Clip, right: Clip)
            do {
                pair = try project.splitClip(id: clip.id, atArrangementBeat: playhead)
            } catch {
                failures += 1
                first = first ?? "trial \(trial): split threw \(error) at local \(local) of \(clipLen)"
                continue
            }

            let left = pair.left
            let right = pair.right
            let leftNotes = left.midiNotes ?? []
            let rightNotes = right.midiNotes ?? []

            // Clip halves: lengths sum to original; abut with no gap.
            let halfSum = left.lengthBeats + right.lengthBeats
            if !almostEqual(halfSum, clipLen) {
                failures += 1
                first = first ?? "trial \(trial): half lengths \(left.lengthBeats)+\(right.lengthBeats)=\(halfSum) != \(clipLen)"
                continue
            }
            if !almostEqual(left.startBeat, clipStart) {
                failures += 1
                first = first ?? "trial \(trial): left start \(left.startBeat) != \(clipStart)"
                continue
            }
            if !almostEqual(right.startBeat, playhead) {
                failures += 1
                first = first ?? "trial \(trial): right start \(right.startBeat) != playhead \(playhead)"
                continue
            }
            if !almostEqual(left.startBeat + left.lengthBeats, right.startBeat) {
                failures += 1
                first = first ?? "trial \(trial): gap/overlap between halves"
                continue
            }
            if !almostEqual(right.startBeat + right.lengthBeats, clipStart + clipLen) {
                failures += 1
                first = first ?? "trial \(trial): right end does not match original end"
                continue
            }

            // Note count: preserved or grows by exactly the number of crossing notes.
            let newCount = leftNotes.count + rightNotes.count
            if newCount != expectedNoteCount {
                failures += 1
                first = first ?? "trial \(trial): note count \(newCount) != \(expectedNoteCount) (orig \(notes.count) + crossing \(crossingCount))"
                continue
            }

            // Total note duration exactly preserved.
            let newTotal = (leftNotes + rightNotes).map(\.lengthBeats).reduce(0, +)
            if !almostEqual(newTotal, origTotalDuration) {
                failures += 1
                first = first ?? "trial \(trial): total duration \(newTotal) != \(origTotalDuration)"
                continue
            }

            // Independent partition oracle: every original note accounted for with
            // correct rebased starts and crossing halves that sum to the original.
            if let msg = verifySplitPartition(
                original: notes, local: local, left: leftNotes, right: rightNotes
            ) {
                failures += 1
                first = first ?? "trial \(trial): \(msg)"
                continue
            }
        }

        // Controlled case: one note entirely before, one crossing, one after.
        do {
            var p = Project.newUntitled()
            let before = Note(startBeat: 0, lengthBeats: 2, pitch: 60, velocity: 100)
            let crossing = Note(startBeat: 3, lengthBeats: 3, pitch: 64, velocity: 90)
            let after = Note(startBeat: 5, lengthBeats: 1.5, pitch: 67, velocity: 80)
            let clip = Clip(kind: .midi, name: "ctrl", startBeat: 4, lengthBeats: 8,
                            midiNotes: [before, crossing, after])
            p.tracks[0].clips = [clip]
            let pair = try p.splitClip(id: clip.id, atArrangementBeat: 8)
            let ln = pair.left.midiNotes ?? []
            let rn = pair.right.midiNotes ?? []
            let total = (ln + rn).map(\.lengthBeats).reduce(0, +)
            if !almostEqual(total, 6.5) {
                failures += 1
                first = first ?? "control: total duration \(total) != 6.5"
            }
            if ln.count + rn.count != 4 {
                failures += 1
                first = first ?? "control: expected 4 notes after split, got \(ln.count + rn.count)"
            }
            // Crossing halves sum to original.
            let leftCross = ln.first { $0.pitch == 64 }
            let rightCross = rn.first { $0.pitch == 64 }
            if let lc = leftCross, let rc = rightCross {
                if !almostEqual(lc.lengthBeats + rc.lengthBeats, 3) {
                    failures += 1
                    first = first ?? "control: crossing halves \(lc.lengthBeats)+\(rc.lengthBeats) != 3"
                }
            } else {
                failures += 1
                first = first ?? "control: missing crossing halves"
            }
        } catch {
            failures += 1
            first = first ?? "control split threw \(error)"
        }

        tk.expect(failures == 0, "split invariants hold",
                  first ?? "all \(trials) trials + control ok")
        tk.expectEqual(failures, 0, "split failure count is zero")
    }
}

/// Match production partition without relying on production code paths: every original note
/// must appear as left-only, right-only (rebased), or a crossing pair whose lengths sum to
/// the original and whose starts are correct.
private func verifySplitPartition(
    original: [Note],
    local: Double,
    left: [Note],
    right: [Note]
) -> String? {
    // Multiset match by (pitch, velocity, length contribution) is awkward after split.
    // Instead: classify each original note and consume matching pieces from left/right.
    var leftPool = left
    var rightPool = right

    for note in original {
        let noteEnd = note.startBeat + note.lengthBeats
        if noteEnd <= local {
            // Entirely left: same start and length.
            guard let idx = leftPool.firstIndex(where: {
                $0.pitch == note.pitch
                    && $0.velocity == note.velocity
                    && almostEqual($0.startBeat, note.startBeat)
                    && almostEqual($0.lengthBeats, note.lengthBeats)
            }) else {
                return "missing left-only note pitch \(note.pitch) start \(note.startBeat)"
            }
            leftPool.remove(at: idx)
        } else if note.startBeat >= local {
            let rebased = note.startBeat - local
            guard let idx = rightPool.firstIndex(where: {
                $0.pitch == note.pitch
                    && $0.velocity == note.velocity
                    && almostEqual($0.startBeat, rebased)
                    && almostEqual($0.lengthBeats, note.lengthBeats)
            }) else {
                return "missing right-only note pitch \(note.pitch) rebased \(rebased)"
            }
            rightPool.remove(at: idx)
        } else {
            // Crossing: left ends at boundary, right starts at 0; lengths sum to original.
            let leftPart = local - note.startBeat
            let rightPart = noteEnd - local
            guard let li = leftPool.firstIndex(where: {
                $0.pitch == note.pitch
                    && $0.velocity == note.velocity
                    && almostEqual($0.startBeat, note.startBeat)
                    && almostEqual($0.lengthBeats, leftPart)
            }) else {
                return "missing crossing left half pitch \(note.pitch)"
            }
            leftPool.remove(at: li)
            guard let ri = rightPool.firstIndex(where: {
                $0.pitch == note.pitch
                    && $0.velocity == note.velocity
                    && almostEqual($0.startBeat, 0)
                    && almostEqual($0.lengthBeats, rightPart)
            }) else {
                return "missing crossing right half pitch \(note.pitch)"
            }
            rightPool.remove(at: ri)
            if !almostEqual(leftPart + rightPart, note.lengthBeats) {
                return "crossing halves \(leftPart)+\(rightPart) != \(note.lengthBeats)"
            }
        }
    }

    if !leftPool.isEmpty || !rightPool.isEmpty {
        return "leftover notes after partition (left \(leftPool.count), right \(rightPool.count))"
    }
    return nil
}

// MARK: - 3. Group move

private func runGroupMoveProperty(_ tk: TestKit) {
    let seed: UInt64 = 0xA515_0003
    let trials = 150

    tk.suite("V5 note group-move property (seed 0xA5150003, \(trials) trials)") {
        var rng = SeededRNG(seed: seed)
        var failures = 0
        var first: String?

        for trial in 0..<trials {
            let n = rng.nextInt(in: 1...8)
            var origins: [(pitch: Int, startBeat: Double)] = []
            for _ in 0..<n {
                origins.append((
                    pitch: rng.nextInt(in: 0...127),
                    startBeat: rng.nextDouble(in: 0...32)
                ))
            }
            let pitchDelta = rng.nextInt(in: -40...40)
            let beatDelta = rng.nextDouble(in: -8...8)

            let result = PianoRollSelection.applyGroupDelta(
                origins: origins, pitchDelta: pitchDelta, beatDelta: beatDelta)

            // Independent legality check: every member in range after delta.
            let independentOK = origins.allSatisfy { o in
                let p = o.pitch + pitchDelta
                let s = o.startBeat + beatDelta
                return p >= 0 && p <= 127 && s >= 0
            }

            if independentOK {
                guard let result else {
                    failures += 1
                    first = first ?? "trial \(trial): legal move rejected"
                    continue
                }
                if result.count != origins.count {
                    failures += 1
                    first = first ?? "trial \(trial): result count changed"
                    continue
                }
                // Applied entirely: each origin shifted by the same deltas.
                for i in origins.indices {
                    if result[i].pitch != origins[i].pitch + pitchDelta
                        || !almostEqual(result[i].startBeat, origins[i].startBeat + beatDelta) {
                        failures += 1
                        first = first ?? "trial \(trial): member \(i) not shifted correctly"
                        break
                    }
                    if result[i].pitch < 0 || result[i].pitch > 127 || result[i].startBeat < 0 {
                        failures += 1
                        first = first ?? "trial \(trial): member \(i) left legal range"
                        break
                    }
                }
                // Relative offsets preserved exactly.
                if let msg = relativeOffsetsPreservedNotes(origins: origins, result: result) {
                    failures += 1
                    first = first ?? "trial \(trial): \(msg)"
                }
            } else {
                // Whole group rejected: not applied at all.
                if result != nil {
                    failures += 1
                    first = first ?? "trial \(trial): illegal move accepted"
                }
            }
        }

        tk.expect(failures == 0, "note group-move invariants hold",
                  first ?? "all \(trials) trials ok")
        tk.expectEqual(failures, 0, "note group-move failure count is zero")
    }

    tk.suite("V5 clip group-move property (seed 0xA5150003b, \(trials) trials)") {
        var rng = SeededRNG(seed: 0xA515_0003_B)
        var failures = 0
        var first: String?

        for trial in 0..<trials {
            let trackCount = rng.nextInt(in: 1...8)
            let n = rng.nextInt(in: 1...6)
            var origins: [(startBeat: Double, trackIndex: Int)] = []
            for _ in 0..<n {
                origins.append((
                    startBeat: rng.nextDouble(in: 0...32),
                    trackIndex: rng.nextInt(in: 0...(trackCount - 1))
                ))
            }
            let beatDelta = rng.nextDouble(in: -8...8)
            let trackDelta = rng.nextInt(in: -4...4)

            let result = ArrangementSelection.applyGroupDelta(
                origins: origins,
                beatDelta: beatDelta,
                trackDelta: trackDelta,
                trackCount: trackCount
            )

            let independentOK = origins.allSatisfy { o in
                let s = o.startBeat + beatDelta
                let t = o.trackIndex + trackDelta
                return s >= 0 && t >= 0 && t < trackCount
            }

            if independentOK {
                guard let result else {
                    failures += 1
                    first = first ?? "trial \(trial): legal clip move rejected"
                    continue
                }
                for i in origins.indices {
                    if result[i].trackIndex != origins[i].trackIndex + trackDelta
                        || !almostEqual(result[i].startBeat, origins[i].startBeat + beatDelta) {
                        failures += 1
                        first = first ?? "trial \(trial): clip member \(i) not shifted correctly"
                        break
                    }
                    if result[i].startBeat < 0
                        || result[i].trackIndex < 0
                        || result[i].trackIndex >= trackCount {
                        failures += 1
                        first = first ?? "trial \(trial): clip member \(i) left legal range"
                        break
                    }
                }
                if let msg = relativeOffsetsPreservedClips(origins: origins, result: result) {
                    failures += 1
                    first = first ?? "trial \(trial): \(msg)"
                }
            } else if result != nil {
                failures += 1
                first = first ?? "trial \(trial): illegal clip move accepted"
            }
        }

        // trackCount == 0 always rejects.
        let empty = ArrangementSelection.applyGroupDelta(
            origins: [(startBeat: 1, trackIndex: 0)],
            beatDelta: 0, trackDelta: 0, trackCount: 0)
        if empty != nil {
            failures += 1
            first = first ?? "trackCount 0 should reject"
        }

        tk.expect(failures == 0, "clip group-move invariants hold",
                  first ?? "all \(trials) trials ok")
        tk.expectEqual(failures, 0, "clip group-move failure count is zero")
    }
}

private func relativeOffsetsPreservedNotes(
    origins: [(pitch: Int, startBeat: Double)],
    result: [(pitch: Int, startBeat: Double)]
) -> String? {
    guard origins.count >= 2 else { return nil }
    for i in 0..<origins.count {
        for j in (i + 1)..<origins.count {
            let dp0 = origins[i].pitch - origins[j].pitch
            let dp1 = result[i].pitch - result[j].pitch
            if dp0 != dp1 {
                return "pitch interval \(i)-\(j) changed (\(dp0) → \(dp1))"
            }
            let ds0 = origins[i].startBeat - origins[j].startBeat
            let ds1 = result[i].startBeat - result[j].startBeat
            if !almostEqual(ds0, ds1) {
                return "beat interval \(i)-\(j) changed (\(ds0) → \(ds1))"
            }
        }
    }
    return nil
}

private func relativeOffsetsPreservedClips(
    origins: [(startBeat: Double, trackIndex: Int)],
    result: [(startBeat: Double, trackIndex: Int)]
) -> String? {
    guard origins.count >= 2 else { return nil }
    for i in 0..<origins.count {
        for j in (i + 1)..<origins.count {
            if origins[i].trackIndex - origins[j].trackIndex
                != result[i].trackIndex - result[j].trackIndex {
                return "track interval \(i)-\(j) changed"
            }
            let ds0 = origins[i].startBeat - origins[j].startBeat
            let ds1 = result[i].startBeat - result[j].startBeat
            if !almostEqual(ds0, ds1) {
                return "clip beat interval \(i)-\(j) changed"
            }
        }
    }
    return nil
}

// MARK: - 4. Marquee hit-testing

private func runMarqueeProperty(_ tk: TestKit) {
    let seed: UInt64 = 0xA515_0004
    let trials = 150

    tk.suite("V5 note marquee property (seed 0xA5150004, \(trials) trials + degenerates)") {
        var rng = SeededRNG(seed: seed)
        var failures = 0
        var first: String?

        for trial in 0..<trials {
            let noteCount = rng.nextInt(in: 1...16)
            var notes: [Note] = []
            for _ in 0..<noteCount {
                notes.append(Note(
                    id: rng.nextUUID(),
                    startBeat: rng.nextDouble(in: 0...16),
                    lengthBeats: rng.nextDouble(in: 0.0625...4),
                    pitch: rng.nextInt(in: 0...127),
                    velocity: 100
                ))
            }

            // Random marquee corners, including inverted drag and zero span.
            var beatA = rng.nextDouble(in: -2...20)
            var beatB = rng.nextDouble(in: -2...20)
            var pitchA = rng.nextInt(in: 0...127)
            var pitchB = rng.nextInt(in: 0...127)
            // Force some degenerate cases every ~5 trials.
            switch trial % 7 {
            case 0: beatB = beatA                                    // zero width
            case 1: pitchB = pitchA                                  // zero height
            case 2: beatB = beatA; pitchB = pitchA                   // point
            case 3: swap(&beatA, &beatB); swap(&pitchA, &pitchB)     // inverted
            default: break
            }

            let hits = Set(PianoRollSelection.notesTouchingMarquee(
                notes: notes, beatA: beatA, beatB: beatB, pitchA: pitchA, pitchB: pitchB))

            // Oracle: same geometry as the documented half-open time / inclusive pitch rule.
            var expected = Set<UUID>()
            for n in notes {
                if noteIntersectsMarqueeOracle(
                    note: n, beatA: beatA, beatB: beatB, pitchA: pitchA, pitchB: pitchB
                ) {
                    expected.insert(n.id)
                }
            }

            if hits != expected {
                failures += 1
                first = first ?? "trial \(trial): hits \(hits.count) != expected \(expected.count) (only hits \(hits.subtracting(expected).count), only expected \(expected.subtracting(hits).count))"
                continue
            }

            // notesTouchingMarquee agrees with per-note noteTouchesMarquee.
            for n in notes {
                let single = PianoRollSelection.noteTouchesMarquee(
                    note: n, beatA: beatA, beatB: beatB, pitchA: pitchA, pitchB: pitchB)
                if single != hits.contains(n.id) {
                    failures += 1
                    first = first ?? "trial \(trial): bulk/single disagree on \(n.id)"
                    break
                }
            }

            // Inverted drag (swap corners) yields the same selection.
            let inverted = Set(PianoRollSelection.notesTouchingMarquee(
                notes: notes, beatA: beatB, beatB: beatA, pitchA: pitchB, pitchB: pitchA))
            if inverted != hits {
                failures += 1
                first = first ?? "trial \(trial): inverted drag changed selection"
            }
        }

        // Explicit degenerate marquee cases (documented in the step).
        let a = Note(startBeat: 2, lengthBeats: 2, pitch: 60, velocity: 100) // 2…4
        let b = Note(startBeat: 5, lengthBeats: 1, pitch: 64, velocity: 100) // 5…6
        let notes = [a, b]

        // Zero width through body of a at pitch 60: hits a only.
        let zw = PianoRollSelection.notesTouchingMarquee(
            notes: notes, beatA: 3, beatB: 3, pitchA: 60, pitchB: 60)
        if Set(zw) != Set([a.id]) {
            failures += 1
            first = first ?? "zero-width marquee through a should hit only a"
        }

        // Zero width exactly at a's end (beat 4): half-open, no hit.
        let zwEnd = PianoRollSelection.noteTouchesMarquee(
            note: a, beatA: 4, beatB: 4, pitchA: 60, pitchB: 60)
        if zwEnd {
            failures += 1
            first = first ?? "zero-width at note end should not touch"
        }

        // Zero height at pitch 60 spanning beats 0…10: hits a only.
        let zh = PianoRollSelection.notesTouchingMarquee(
            notes: notes, beatA: 0, beatB: 10, pitchA: 60, pitchB: 60)
        if Set(zh) != Set([a.id]) {
            failures += 1
            first = first ?? "zero-height marquee at pitch 60 should hit only a"
        }

        // Inverted drag (end before start in both axes) still hits a.
        let inv = PianoRollSelection.notesTouchingMarquee(
            notes: notes, beatA: 4, beatB: 1, pitchA: 70, pitchB: 55)
        if Set(inv) != Set([a.id]) {
            failures += 1
            first = first ?? "inverted drag should still hit a"
        }

        // Point marquee on empty pitch: hit nothing.
        let miss = PianoRollSelection.notesTouchingMarquee(
            notes: notes, beatA: 3, beatB: 3, pitchA: 100, pitchB: 100)
        if !miss.isEmpty {
            failures += 1
            first = first ?? "point marquee on empty pitch should hit nothing"
        }

        tk.expect(failures == 0, "note marquee invariants hold",
                  first ?? "all trials + degenerates ok")
        tk.expectEqual(failures, 0, "note marquee failure count is zero")
    }

    tk.suite("V5 clip marquee property (seed 0xA5150004b, \(trials) trials + degenerates)") {
        var rng = SeededRNG(seed: 0xA515_0004_B)
        var failures = 0
        var first: String?

        for trial in 0..<trials {
            let clipCount = rng.nextInt(in: 1...12)
            var clips: [(id: UUID, startBeat: Double, lengthBeats: Double, trackIndex: Int)] = []
            for _ in 0..<clipCount {
                clips.append((
                    id: rng.nextUUID(),
                    startBeat: rng.nextDouble(in: 0...32),
                    lengthBeats: rng.nextDouble(in: 0.25...8),
                    trackIndex: rng.nextInt(in: 0...7)
                ))
            }

            var beatA = rng.nextDouble(in: -2...40)
            var beatB = rng.nextDouble(in: -2...40)
            var trackA = rng.nextInt(in: 0...7)
            var trackB = rng.nextInt(in: 0...7)
            switch trial % 7 {
            case 0: beatB = beatA
            case 1: trackB = trackA
            case 2: beatB = beatA; trackB = trackA
            case 3: swap(&beatA, &beatB); swap(&trackA, &trackB)
            default: break
            }

            let hits = Set(ArrangementSelection.clipsTouchingMarquee(
                clips: clips, beatA: beatA, beatB: beatB, trackA: trackA, trackB: trackB))

            var expected = Set<UUID>()
            for c in clips {
                if clipIntersectsMarqueeOracle(
                    startBeat: c.startBeat, lengthBeats: c.lengthBeats, trackIndex: c.trackIndex,
                    beatA: beatA, beatB: beatB, trackA: trackA, trackB: trackB
                ) {
                    expected.insert(c.id)
                }
            }

            if hits != expected {
                failures += 1
                first = first ?? "trial \(trial): clip hits mismatch"
                continue
            }

            let inverted = Set(ArrangementSelection.clipsTouchingMarquee(
                clips: clips, beatA: beatB, beatB: beatA, trackA: trackB, trackB: trackA))
            if inverted != hits {
                failures += 1
                first = first ?? "trial \(trial): inverted clip marquee changed selection"
            }
        }

        // Explicit degenerates.
        let c1ID = UUID()
        let c2ID = UUID()
        let clips: [(id: UUID, startBeat: Double, lengthBeats: Double, trackIndex: Int)] = [
            (c1ID, 2, 2, 1), // track 1, beats 2…4
            (c2ID, 5, 1, 3), // track 3, beats 5…6
        ]

        // Zero width through c1 body on track 1.
        let zw = ArrangementSelection.clipsTouchingMarquee(
            clips: clips, beatA: 3, beatB: 3, trackA: 1, trackB: 1)
        if Set(zw) != Set([c1ID]) {
            failures += 1
            first = first ?? "zero-width clip marquee should hit only c1"
        }

        // Zero height (single track) spanning time: hits c1 only.
        let zh = ArrangementSelection.clipsTouchingMarquee(
            clips: clips, beatA: 0, beatB: 10, trackA: 1, trackB: 1)
        if Set(zh) != Set([c1ID]) {
            failures += 1
            first = first ?? "zero-height clip marquee on track 1 should hit only c1"
        }

        // Inverted drag covering tracks 0…2 and beats 4…1 → normalizes to beats 1…4, tracks 0…2.
        let inv = ArrangementSelection.clipsTouchingMarquee(
            clips: clips, beatA: 4, beatB: 1, trackA: 2, trackB: 0)
        if Set(inv) != Set([c1ID]) {
            failures += 1
            first = first ?? "inverted clip marquee should hit c1"
        }

        // Zero width at clip end: no hit.
        let edge = ArrangementSelection.clipTouchesMarquee(
            startBeat: 2, lengthBeats: 2, trackIndex: 1,
            beatA: 4, beatB: 4, trackA: 1, trackB: 1)
        if edge {
            failures += 1
            first = first ?? "zero-width at clip end should not touch"
        }

        tk.expect(failures == 0, "clip marquee invariants hold",
                  first ?? "all trials + degenerates ok")
        tk.expectEqual(failures, 0, "clip marquee failure count is zero")
    }
}

/// Independent oracle for note↔marquee intersection (time half-open style, pitch inclusive).
private func noteIntersectsMarqueeOracle(
    note: Note,
    beatA: Double, beatB: Double,
    pitchA: Int, pitchB: Int
) -> Bool {
    let beatLo = min(beatA, beatB)
    let beatHi = max(beatA, beatB)
    let pitchLo = min(pitchA, pitchB)
    let pitchHi = max(pitchA, pitchB)
    let noteLo = note.startBeat
    let noteHi = note.startBeat + note.lengthBeats
    let timeOverlap = noteLo < beatHi && noteHi > beatLo
    let pitchOverlap = note.pitch >= pitchLo && note.pitch <= pitchHi
    return timeOverlap && pitchOverlap
}

/// Independent oracle for clip↔marquee intersection (same time rule, track inclusive).
private func clipIntersectsMarqueeOracle(
    startBeat: Double, lengthBeats: Double, trackIndex: Int,
    beatA: Double, beatB: Double,
    trackA: Int, trackB: Int
) -> Bool {
    let beatLo = min(beatA, beatB)
    let beatHi = max(beatA, beatB)
    let trackLo = min(trackA, trackB)
    let trackHi = max(trackA, trackB)
    let clipHi = startBeat + lengthBeats
    let timeOverlap = startBeat < beatHi && clipHi > beatLo
    let trackOverlap = trackIndex >= trackLo && trackIndex <= trackHi
    return timeOverlap && trackOverlap
}

// MARK: - 5. Beat-to-x mapping

private func runBeatToXProperty(_ tk: TestKit) {
    let seed: UInt64 = 0xA515_0005
    let trials = 200

    tk.suite("V5 BeatTimeline beat↔x property (seed 0xA5150005, \(trials) trials)") {
        var rng = SeededRNG(seed: seed)
        var failures = 0
        var first: String?

        // Arrangement and roll share this mapping; one function pair is the agreement.
        tk.expectEqual(BeatTimeline.baseBeatWidth, 28, "base pixels-per-beat is 28")
        tk.expectEqual(BeatTimeline.beatWidth(zoom: 1.0), 28, "zoom 1.0 yields base width")

        // Property holds at default zoom and at a non-default shared zoom.
        let zooms: [Double] = [1.0, 0.5, 2.0, 1.25]
        for zoom in zooms {
            for trial in 0..<trials {
                let beat = rng.nextDouble(in: 0...256)
                let x = BeatTimeline.x(forBeat: beat, zoom: zoom)
                let back = BeatTimeline.beat(atX: x, zoom: zoom)

                // Round-trip within rounding tolerance (CGFloat path on the mapping).
                if abs(back - beat) > 1e-9 {
                    failures += 1
                    first = first ?? "trial \(trial) zoom \(zoom): round-trip beat \(beat) → x \(x) → \(back)"
                    continue
                }

                // Closed form: both views use the same scale, so x is beat × beatWidth(zoom).
                let expectedX = CGFloat(beat) * BeatTimeline.beatWidth(zoom: zoom)
                if abs(x - expectedX) > 1e-9 {
                    failures += 1
                    first = first ?? "trial \(trial) zoom \(zoom): x \(x) != beat×width \(expectedX)"
                    continue
                }

                // width(forBeats:) agrees with x of a duration from 0.
                let w = BeatTimeline.width(forBeats: beat, zoom: zoom)
                if abs(w - x) > 1e-9 {
                    failures += 1
                    first = first ?? "trial \(trial) zoom \(zoom): width(forBeats:) \(w) != x(forBeat:) \(x)"
                }
            }

            // Absolute / local invert for random clip placements (roll note under arrangement).
            for trial in 0..<trials {
                let clipStart = rng.nextDouble(in: 0...64)
                let local = rng.nextDouble(in: 0...16)
                let absolute = BeatTimeline.absoluteStart(clipStart: clipStart, noteLocalStart: local)
                let backLocal = BeatTimeline.localBeat(absolute: absolute, clipStart: clipStart)
                if abs(backLocal - local) > 1e-12 {
                    failures += 1
                    first = first ?? "trial \(trial) zoom \(zoom): local/absolute invert failed"
                    continue
                }
                // Note at local L in clip at S shares x with arrangement event at S+L (same zoom).
                let noteX = BeatTimeline.x(forBeat: absolute, zoom: zoom)
                let arrX = BeatTimeline.x(forBeat: clipStart + local, zoom: zoom)
                if abs(noteX - arrX) > 1e-9 {
                    failures += 1
                    first = first ?? "trial \(trial) zoom \(zoom): roll and arrangement disagree on x"
                }
            }
        }

        // Fixed anchors.
        if BeatTimeline.x(forBeat: 0) != 0 {
            failures += 1
            first = first ?? "beat 0 not at x 0"
        }
        if BeatTimeline.beat(atX: 0) != 0 {
            failures += 1
            first = first ?? "x 0 not beat 0"
        }

        tk.expect(failures == 0, "beat↔x invariants hold",
                  first ?? "all \(trials) trials ok")
        tk.expectEqual(failures, 0, "beat↔x failure count is zero")
    }
}

// MARK: - Float helper

/// Exact equality for values that should be bit-identical after add/sub, with a tiny
/// epsilon for CGFloat path noise on beat↔x. Duration and split math use this so a real
/// duration leak fails while harmless binary rounding does not.
private func almostEqual(_ a: Double, _ b: Double, eps: Double = 1e-12) -> Bool {
    if a == b { return true }
    return abs(a - b) <= eps
}
