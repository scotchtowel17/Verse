import Foundation
import VerseModel
import VerseEngine
import VersePersistence
import VerseAI
import VerseAppCore

/// Phase AC headless probes: areas that do not need a UI. Asserts observable
/// AppStore / Project outcomes only. UI/View files are never touched here.
func runACProbeChecks(_ tk: TestKit) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { runACProbeChecksOnMain(tk) }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { runACProbeChecksOnMain(tk) }
        }
    }
}

@MainActor
private func makeACStore() -> (AppStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("VerseCheck-AC-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = AppStore(recoveryBaseDir: dir)
    return (store, dir)
}

/// Project identity for boundary checks: serialised JSON when available, else a field digest.
@MainActor
private func projectFingerprint(_ project: Project) -> String {
    if let data = try? project.jsonData() {
        return String(data: data, encoding: .utf8) ?? data.base64EncodedString()
    }
    // Fallback digest if encoding fails (should not happen for a live project).
    let clipBits = project.tracks.map { t in
        t.clips.map { c in
            "\(c.id.uuidString):\(c.startBeat):\(c.lengthBeats):\(c.mediaStartSeconds):n\(c.midiNotes?.count ?? 0)"
        }.joined(separator: ",")
    }.joined(separator: "|")
    return "\(project.tempoBPM ?? -1)|\(project.tracks.count)|\(clipBits)|\(project.timeSignature.num)/\(project.timeSignature.den)"
}

@MainActor
private func runACProbeChecksOnMain(_ tk: TestKit) {

    // MARK: - AC1 note resize logic

    tk.suite("AC1: note resize never non-positive; snap lands on grid; handle width safe") {
        // Model path: resizeNote rejects length <= 0; positive sub-minimum floors to 1/32.
        var project = Project.newUntitled()
        let note = Note(startBeat: 1.0, lengthBeats: 2.0, pitch: 60, velocity: 100)
        let sibling = Note(startBeat: 4.0, lengthBeats: 1.0, pitch: 64, velocity: 90)
        let clip = Clip(kind: .midi, name: "AC1", startBeat: 0, lengthBeats: 16,
                        midiNotes: [note, sibling])
        project.tracks[0].clips = [clip]
        let noteID = note.id
        let clipID = clip.id

        // Positive lengths: never produce length <= 0.
        for raw in [0.01, 0.05, Project.minimumNoteLengthBeats, 0.25, 1.0, 3.5, 8.0] {
            try project.resizeNote(id: noteID, inClip: clipID, toLengthBeats: raw)
            let len = project.tracks[0].clips[0].midiNotes![0].lengthBeats
            tk.expect(len > 0, "resize raw \(raw) produces length > 0 (got \(len))")
            if raw > 0 && raw < Project.minimumNoteLengthBeats {
                tk.expectEqual(len, Project.minimumNoteLengthBeats,
                               "sub-minimum \(raw) floors to minimumNoteLengthBeats")
            } else if raw >= Project.minimumNoteLengthBeats {
                tk.expectEqual(len, raw, "in-range resize stores exact length \(raw)")
            }
        }
        // Sibling and other fields untouched by last resize.
        let afterPos = project.tracks[0].clips[0].midiNotes!
        tk.expectEqual(afterPos[0].startBeat, 1.0, "resize leaves startBeat")
        tk.expectEqual(afterPos[0].pitch, 60, "resize leaves pitch")
        tk.expectEqual(afterPos[0].velocity, 100, "resize leaves velocity")
        tk.expectEqual(afterPos[1].lengthBeats, 1.0, "sibling length untouched")
        tk.expectEqual(afterPos[1].id, sibling.id, "sibling id untouched")

        // Length <= 0 would place the note end at or before its start: rejected.
        let lenBeforeReject = project.tracks[0].clips[0].midiNotes![0].lengthBeats
        tk.expectThrows("resize length 0 (end at start) rejected") {
            try project.resizeNote(id: noteID, inClip: clipID, toLengthBeats: 0)
        }
        tk.expectThrows("resize negative length (end before start) rejected") {
            try project.resizeNote(id: noteID, inClip: clipID, toLengthBeats: -1.5)
        }
        tk.expectEqual(project.tracks[0].clips[0].midiNotes![0].lengthBeats, lenBeforeReject,
                       "rejected resize leaves prior length")
        tk.expectEqual(project.tracks[0].clips[0].midiNotes![0].startBeat, 1.0,
                       "rejected resize leaves startBeat")

        // Snap each picker grid: UI floors at minimumNoteLengthBeats then resizes.
        // For grid > 0, snapped values at or above the grid land on an exact multiple.
        for opt in SnapGrid.pickerOptions {
            let grid = opt.beats
            let label = opt.label
            if grid <= 0 {
                // Off: snap is identity; a free length still stays positive via the floor.
                let free = 1.37
                let snappedOff = max(Project.minimumNoteLengthBeats,
                                     PianoRollLayout.snap(free, to: grid))
                tk.expectEqual(snappedOff, free, "snap Off is identity for \(free)")
                try project.resizeNote(id: noteID, inClip: clipID, toLengthBeats: snappedOff)
                let got = project.tracks[0].clips[0].midiNotes![0].lengthBeats
                tk.expect(got > 0, "Off-grid resize length > 0")
                continue
            }
            // Snap alone lands on a grid multiple. UI then floors at minimumNoteLengthBeats
            // so the note stays visible; that floor can leave a non-multiple when the snap
            // would otherwise sit below the minimum (e.g. 1/16T grid vs 1/32 floor).
            let raws = [grid * 0.4, grid * 1.0, grid * 1.5, grid * 2.0, grid * 3.7, grid * 8.0]
            for raw in raws {
                let pureSnap = PianoRollLayout.snap(raw, to: grid)
                let q = (pureSnap / grid).rounded()
                let err = abs(pureSnap - q * grid)
                tk.expect(err < 1e-9,
                          "\(label) pure snap of \(raw) is grid multiple (got \(pureSnap), err \(err))")
                let applied = max(Project.minimumNoteLengthBeats, pureSnap)
                tk.expect(applied > 0, "\(label) applied length of \(raw) is positive")
                if pureSnap >= Project.minimumNoteLengthBeats - 1e-12 {
                    let q2 = (applied / grid).rounded()
                    tk.expect(abs(applied - q2 * grid) < 1e-9,
                              "\(label) applied \(applied) stays grid multiple when above floor")
                }
                try project.resizeNote(id: noteID, inClip: clipID, toLengthBeats: applied)
                let stored = project.tracks[0].clips[0].midiNotes![0].lengthBeats
                tk.expect(stored > 0, "\(label) stored length > 0 after resize to \(applied)")
                tk.expectEqual(stored, applied, "\(label) stores applied length \(applied)")
            }
        }

        // Resize handle: never larger than the note, never negative, for widths 0...400.
        for wInt in 0...400 {
            let w = CGFloat(wInt)
            let handle = PianoRollLayout.resizeHandleWidth(noteWidth: w)
            tk.expect(handle >= 0, "handle width non-negative at noteWidth \(wInt) (got \(handle))")
            if w <= 0 {
                tk.expectEqual(handle, 0, "handle is 0 when noteWidth is \(wInt)")
            } else {
                tk.expect(handle <= w + 1e-9,
                          "handle never wider than note at \(wInt) (handle \(handle), note \(w))")
                tk.expect(handle <= PianoRollLayout.resizeHandleMaxWidth + 1e-9,
                          "handle capped at max at \(wInt)")
            }
        }
        // Spot-check the 30% rule on a short note and the max on a wide note.
        tk.expectEqual(PianoRollLayout.resizeHandleWidth(noteWidth: 10),
                       10 * PianoRollLayout.resizeHandleFraction,
                       "short note uses fraction of width")
        tk.expectEqual(PianoRollLayout.resizeHandleWidth(noteWidth: 100),
                       PianoRollLayout.resizeHandleMaxWidth,
                       "wide note uses max handle width")

        // AppStore continuous path: same no-non-positive guarantee via gesture API.
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aNote = Note(startBeat: 0, lengthBeats: 2, pitch: 72, velocity: 100)
        let aClip = Clip(kind: .midi, name: "AS-AC1", startBeat: 0, lengthBeats: 8,
                         midiNotes: [aNote])
        store.project.tracks[0].clips = [aClip]
        store.openPianoRoll(clipID: aClip.id)
        store.beginPianoRollGesture(name: "Resize Note")
        store.pianoRollResizeNote(id: aNote.id, toLengthBeats: 0.01)
        store.pianoRollResizeNote(id: aNote.id, toLengthBeats: 0) // must not leave length <= 0
        store.pianoRollResizeNote(id: aNote.id, toLengthBeats: -2)
        store.endPianoRollGesture()
        let asLen = store.project.tracks[0].clips[0].midiNotes![0].lengthBeats
        tk.expect(asLen > 0, "AppStore resize path never leaves length <= 0 (got \(asLen))")
        tk.expectEqual(asLen, Project.minimumNoteLengthBeats,
                       "AppStore last accepted sub-minimum floors to minimum")
    }

    // MARK: - AC2 velocity

    tk.suite("AC2: velocity clamp 1...127 never 0; multi-note set is one undo; other fields intact") {
        // Pure clamp: inputs -100...300 land in 1...127 and never 0.
        for v in -100...300 {
            let c = PianoRollSelection.clampedVelocity(v)
            tk.expect(c >= 1 && c <= 127,
                      "clampedVelocity(\(v)) in 1...127 (got \(c))")
            tk.expect(c != 0, "clampedVelocity(\(v)) is never 0 (MIDI note-off)")
        }
        tk.expectEqual(PianoRollSelection.clampedVelocity(0), 1, "0 clamps to 1")
        tk.expectEqual(PianoRollSelection.clampedVelocity(1), 1, "1 stays 1")
        tk.expectEqual(PianoRollSelection.clampedVelocity(64), 64, "64 stays 64")
        tk.expectEqual(PianoRollSelection.clampedVelocity(127), 127, "127 stays 127")
        tk.expectEqual(PianoRollSelection.clampedVelocity(128), 127, "128 clamps to 127")
        tk.expectEqual(PianoRollSelection.clampedVelocity(-1), 1, "-1 clamps to 1")

        // Multi-note selection: one undo entry; pitch/start/length/id untouched.
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let n1 = Note(startBeat: 0.0, lengthBeats: 1.0, pitch: 60, velocity: 40)
        let n2 = Note(startBeat: 1.5, lengthBeats: 0.5, pitch: 64, velocity: 80)
        let n3 = Note(startBeat: 3.0, lengthBeats: 2.0, pitch: 67, velocity: 110)
        let clip = Clip(kind: .midi, name: "AC2", startBeat: 0, lengthBeats: 16,
                        midiNotes: [n1, n2, n3])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)
        tk.expect(!store.canUndo, "no undo before velocity gesture")

        let origins = [n1, n2, n3]
        store.beginPianoRollGesture(name: "Set Velocity")
        // Several continuous updates (as a drag would fire); final targets via group delta.
        for step in 1...20 {
            let proposed = PianoRollSelection.applyGroupVelocityDelta(
                origins: origins.map(\.velocity), delta: step)
            store.pianoRollSetNoteVelocities([
                (id: n1.id, velocity: proposed[0]),
                (id: n2.id, velocity: proposed[1]),
                (id: n3.id, velocity: proposed[2]),
            ])
        }
        store.endPianoRollGesture()

        let after = store.project.tracks[0].clips[0].midiNotes!
        tk.expectEqual(after.count, 3, "still three notes after velocity set")
        for i in origins.indices {
            tk.expectEqual(after[i].id, origins[i].id, "note \(i) id untouched")
            tk.expectEqual(after[i].pitch, origins[i].pitch, "note \(i) pitch untouched")
            tk.expectEqual(after[i].startBeat, origins[i].startBeat, "note \(i) start untouched")
            tk.expectEqual(after[i].lengthBeats, origins[i].lengthBeats,
                           "note \(i) length untouched")
            tk.expect(after[i].velocity >= 1 && after[i].velocity <= 127,
                      "note \(i) velocity in 1...127")
        }
        // Explicit final values for +20: 60, 100, 127 (hard clamps).
        tk.expectEqual(after[0].velocity, 60, "n1 velocity +20")
        tk.expectEqual(after[1].velocity, 100, "n2 velocity +20")
        tk.expectEqual(after[2].velocity, 127, "n3 velocity clamps at 127")
        tk.expectEqual(store.undoName, "Set Velocity", "velocity gesture undo label")
        tk.expect(store.canUndo, "undo available after multi-note velocity")

        // Exactly one undo entry: undo once empties the stack and restores every field.
        store.undo()
        tk.expect(!store.canUndo, "single undo empties stack (one entry for multi-note)")
        let restored = store.project.tracks[0].clips[0].midiNotes!
        for i in origins.indices {
            tk.expectEqual(restored[i].velocity, origins[i].velocity,
                           "undo restores note \(i) velocity")
            tk.expectEqual(restored[i].pitch, origins[i].pitch, "undo keeps note \(i) pitch")
            tk.expectEqual(restored[i].startBeat, origins[i].startBeat,
                           "undo keeps note \(i) start")
            tk.expectEqual(restored[i].lengthBeats, origins[i].lengthBeats,
                           "undo keeps note \(i) length")
            tk.expectEqual(restored[i].id, origins[i].id, "undo keeps note \(i) id")
        }
        tk.expect(store.canRedo, "can redo multi-note velocity")
        store.redo()
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes![0].velocity, 60,
                       "redo restores multi-note velocities")
    }

    // MARK: - AC3 loop region

    tk.suite("AC3: LoopRegionLogic normalize/move/resize; playbackLoop and playbackStart cases") {
        // normalized(): inverted input and too-short regions.
        let inverted = LoopRegionLogic.normalized(start: 8, end: 2)
        tk.expectEqual(inverted?.lowerBound, 2, "inverted start>end → lower is min")
        tk.expectEqual(inverted?.upperBound, 8, "inverted start>end → upper is max")
        tk.expect(LoopRegionLogic.normalized(start: 4, end: 4) == nil,
                  "zero-length region rejected")
        tk.expect(LoopRegionLogic.normalized(start: 1, end: 1 + LoopRegionLogic.minimumLengthBeats - 0.01) == nil,
                  "sub-minimum length rejected")
        let justEnough = LoopRegionLogic.normalized(
            start: 0, end: LoopRegionLogic.minimumLengthBeats)
        tk.expect(justEnough != nil, "exactly minimumLengthBeats accepted")
        let neg = LoopRegionLogic.normalized(start: -5, end: -1)
        // Both clamped to 0 → zero length → nil
        tk.expect(neg == nil || (neg!.lowerBound >= 0 && neg!.upperBound >= neg!.lowerBound),
                  "negative inputs never produce negative bounds")
        let mixed = LoopRegionLogic.normalized(start: -2, end: 2)
        tk.expectEqual(mixed?.lowerBound, 0, "negative start clamps to 0")
        tk.expectEqual(mixed?.upperBound, 2, "positive end kept")

        // moved(): never produces a negative start; length preserved.
        let base = 4.0...10.0
        let left = LoopRegionLogic.moved(base, by: -100)
        tk.expect(left.lowerBound >= 0, "moved far left has non-negative start")
        tk.expectEqual(left.lowerBound, 0, "moved far left clamps start to 0")
        tk.expectEqual(left.upperBound - left.lowerBound, base.upperBound - base.lowerBound,
                       "moved preserves length when clamped")
        let right = LoopRegionLogic.moved(base, by: 3)
        tk.expectEqual(right.lowerBound, 7, "moved right start")
        tk.expectEqual(right.upperBound, 13, "moved right end")
        tk.expect(right.lowerBound >= 0, "moved right start non-negative")

        // resized() on each edge: keeps start < end or refuses.
        let rStart = LoopRegionLogic.resized(base, edge: .start, to: 6)
        tk.expectEqual(rStart?.lowerBound, 6, "resize start edge")
        tk.expectEqual(rStart?.upperBound, 10, "resize start keeps end")
        tk.expect(rStart!.lowerBound < rStart!.upperBound, "resized start still start < end")
        let rEnd = LoopRegionLogic.resized(base, edge: .end, to: 12)
        tk.expectEqual(rEnd?.lowerBound, 4, "resize end keeps start")
        tk.expectEqual(rEnd?.upperBound, 12, "resize end edge")
        tk.expect(rEnd!.lowerBound < rEnd!.upperBound, "resized end still start < end")
        // Collapse / invert to equal: refuse.
        // Collapse to zero length: refuse.
        tk.expect(LoopRegionLogic.resized(base, edge: .start, to: 10) == nil,
                  "resize start to end refused")
        tk.expect(LoopRegionLogic.resized(base, edge: .end, to: 4) == nil,
                  "resize end to start refused")
        // Start dragged past end with remaining span: normalized reorders so start < end.
        let invertShort = LoopRegionLogic.resized(base, edge: .start, to: 11)
        tk.expectEqual(invertShort?.lowerBound, 10, "start past end reorders lower to old end")
        tk.expectEqual(invertShort?.upperBound, 11, "start past end reorders upper to drag")
        tk.expect(invertShort!.lowerBound < invertShort!.upperBound,
                  "reordered resize keeps start < end")
        let invertResize = LoopRegionLogic.resized(base, edge: .start, to: 14)
        // start=14 end=10 → lo=10 hi=14 length=4 ≥ minimum → accepted reordered
        tk.expectEqual(invertResize?.lowerBound, 10, "inverted resize lower")
        tk.expectEqual(invertResize?.upperBound, 14, "inverted resize upper")
        tk.expect(invertResize!.lowerBound < invertResize!.upperBound,
                  "long inverted resize keeps start < end")

        // playbackLoop: off, nil region, with region.
        tk.expect(LoopRegionLogic.playbackLoop(loopOn: false, region: 0...4, arrangementEnd: 16) == nil,
                  "loop off → nil playback loop")
        tk.expect(LoopRegionLogic.playbackLoop(loopOn: false, region: nil, arrangementEnd: 16) == nil,
                  "loop off + nil region → nil")
        let fallback = LoopRegionLogic.playbackLoop(loopOn: true, region: nil, arrangementEnd: 16)
        tk.expectEqual(fallback?.lowerBound, 0, "nil region fallback starts at 0")
        tk.expectEqual(fallback?.upperBound, 16, "nil region fallback uses arrangementEnd")
        let shortArr = LoopRegionLogic.playbackLoop(loopOn: true, region: nil, arrangementEnd: 1)
        tk.expectEqual(shortArr?.upperBound, 4, "fallback floors at 4 beats")
        let withRegion = LoopRegionLogic.playbackLoop(loopOn: true, region: 2...6, arrangementEnd: 32)
        tk.expectEqual(withRegion, 2...6, "loop on with region uses the region")

        // playbackStart: loop off/nil, playhead before / inside / after region.
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 5, loop: nil), 5,
                       "no loop keeps playhead")
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: -3, loop: nil), 0,
                       "no loop clamps negative playhead to 0")
        let loop = 4.0...12.0
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 2, loop: loop), 4,
                       "playhead before region → loop start")
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 4, loop: loop), 4,
                       "playhead at region start kept")
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 8, loop: loop), 8,
                       "playhead inside region kept")
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 12, loop: loop), 4,
                       "playhead at region end (half-open) → loop start")
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 20, loop: loop), 4,
                       "playhead after region → loop start")
    }

    // MARK: - AC9 track rename / delete

    tk.suite("AC9: rename keeps id/clips/colour; delete one track + undo; last track refused") {
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed track with clips and a non-default colour.
        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 2, lengthBeats: 1, pitch: 64, velocity: 90)
        let clip = Clip(kind: .midi, name: "Phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [n1, n2])
        let seedID = store.project.tracks[0].id
        store.project.tracks[0].clips = [clip]
        store.setTrackColorIndex(5, seedID)
        let colorBefore = store.project.track(id: seedID)!.colorIndex
        let clipIDsBefore = store.project.tracks[0].clips.map(\.id)
        let noteIDsBefore = (store.project.tracks[0].clips[0].midiNotes ?? []).map(\.id)

        store.renameTrack(seedID, to: "Lead Synth")
        let renamed = store.project.track(id: seedID)
        tk.expect(renamed != nil, "renamed track still addressable by same id")
        tk.expectEqual(renamed?.id, seedID, "rename keeps track id")
        tk.expectEqual(renamed?.name, "Lead Synth", "rename sets name")
        tk.expectEqual(renamed?.colorIndex, colorBefore, "rename leaves colorIndex")
        tk.expectEqual(renamed?.clips.map(\.id), clipIDsBefore, "rename leaves clip ids")
        tk.expectEqual((renamed?.clips[0].midiNotes ?? []).map(\.id), noteIDsBefore,
                       "rename leaves note ids")
        tk.expectEqual(renamed?.clips[0].midiNotes?[0].pitch, 60, "rename leaves note pitch")
        tk.expectEqual(store.undoName, "Rename Track", "rename undo label")

        // Second track so delete of one is legal; first still has the clip.
        store.addInstrumentTrack()
        let otherID = store.project.tracks[1].id
        let otherClip = Clip(kind: .midi, name: "Other", startBeat: 4, lengthBeats: 4,
                             midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 72, velocity: 80)])
        store.project.tracks[1].clips = [otherClip]
        let otherClipID = otherClip.id
        let trackCountBeforeDelete = store.project.tracks.count
        tk.expectEqual(trackCountBeforeDelete, 2, "two tracks before delete")

        // Snapshot seed track payload for full restore check.
        let seedSnapshot = store.project.track(id: seedID)!
        let seedName = seedSnapshot.name
        let seedColor = seedSnapshot.colorIndex
        let seedClipCount = seedSnapshot.clips.count
        let seedNotePitch = seedSnapshot.clips[0].midiNotes?[0].pitch

        store.deleteTrack(seedID)
        tk.expectEqual(store.project.tracks.count, 1, "one track remains after delete")
        tk.expect(store.project.track(id: seedID) == nil, "deleted track id gone")
        tk.expect(store.project.track(id: otherID) != nil, "other track still present")
        tk.expectEqual(store.project.tracks[0].id, otherID, "remaining track is the other one")
        tk.expectEqual(store.project.tracks[0].clips.map(\.id), [otherClipID],
                       "only deleted track’s clips removed; other clip intact")
        tk.expectEqual(store.undoName, "Delete Track", "delete undo label")
        tk.expect(store.canUndo, "delete recorded undo")

        // One undo restores the whole deleted track (id, name, colour, clips, notes).
        store.undo()
        tk.expectEqual(store.project.tracks.count, 2, "undo restores track count")
        let restored = store.project.track(id: seedID)
        tk.expect(restored != nil, "undo restores track by original id")
        tk.expectEqual(restored?.name, seedName, "undo restores name")
        tk.expectEqual(restored?.colorIndex, seedColor, "undo restores colorIndex")
        tk.expectEqual(restored?.clips.count, seedClipCount, "undo restores clip count")
        tk.expectEqual(restored?.clips[0].id, clip.id, "undo restores clip id")
        tk.expectEqual(restored?.clips[0].midiNotes?[0].pitch, seedNotePitch,
                       "undo restores note content")
        tk.expectEqual(store.project.track(id: otherID)?.clips.map(\.id), [otherClipID],
                       "other track untouched by undo of delete")
        // Single undo entry: stack empty after one undo of the delete (plus earlier ops exist).
        // The delete itself is one entry: redo delete then undo once.
        store.redo()
        tk.expectEqual(store.project.tracks.count, 1, "redo re-deletes")
        store.undo()
        tk.expectEqual(store.project.tracks.count, 2, "second single-undo restores whole track again")
        tk.expect(store.project.track(id: seedID) != nil, "id restored again")

        // Last remaining track: assert current behaviour (refuse, leave project with one track).
        // Reduce to a single track first.
        while store.project.tracks.count > 1 {
            let doomed = store.project.tracks.last!.id
            store.deleteTrack(doomed)
        }
        tk.expectEqual(store.project.tracks.count, 1, "exactly one track before last-delete attempt")
        let lastID = store.project.tracks[0].id
        let lastName = store.project.tracks[0].name
        let lastFP = projectFingerprint(store.project)
        let statusBefore = store.statusMessage
        store.deleteTrack(lastID)
        tk.expectEqual(store.project.tracks.count, 1,
                       "deleting the last track leaves exactly one track")
        tk.expectEqual(store.project.tracks[0].id, lastID,
                       "last track id unchanged after refuse")
        tk.expectEqual(store.project.tracks[0].name, lastName,
                       "last track name unchanged after refuse")
        tk.expectEqual(projectFingerprint(store.project), lastFP,
                       "refusing last-track delete leaves project unchanged")
        tk.expectEqual(store.statusMessage, "A project needs at least one track.",
                       "last-track delete sets readable status")
        // status must have been set (or already equal); if statusBefore matched by chance, still ok.
        tk.expect(store.statusMessage != nil || statusBefore != nil,
                  "status path exercised for last-track refuse")
    }

    // MARK: - AC15 metronome

    tk.suite("AC15: metronome flag reaches transport; survives play then stop") {
        // AppStore.setMetronome / metronomeOn / transport are internal to VerseAppCore, so
        // VerseCheck exercises the public Transport flag that setMetronome writes and that
        // startPlayback re-applies from the AppStore toggle.
        let mediaDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC15-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mediaDir) }

        let engine = VerseAudioEngine()
        engine.configure(with: Project.newUntitled())
        let transport = Transport(engine: engine)
        var project = Project.newUntitled()
        let clip = Clip(kind: .midi, name: "AC15", startBeat: 0, lengthBeats: 8,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        project.tracks[0].clips = [clip]

        // Toggle on: flag set on transport.
        transport.metronomeEnabled = true
        tk.expect(transport.metronomeEnabled, "toggling on sets transport.metronomeEnabled")

        // Play then stop must not clear the flag (AppStore re-applies it on each start; the
        // transport itself must not silently drop it on stop either).
        transport.play(project: project, mediaDir: mediaDir, from: 0, loop: nil)
        tk.expect(transport.metronomeEnabled, "metronome still on during play")
        transport.stop()
        tk.expect(transport.metronomeEnabled, "metronome still on after stop")

        // Toggle off: same survival through play/stop.
        transport.metronomeEnabled = false
        tk.expect(!transport.metronomeEnabled, "toggling off clears transport.metronomeEnabled")
        transport.play(project: project, mediaDir: mediaDir, from: 0, loop: nil)
        tk.expect(!transport.metronomeEnabled, "metronome still off during play")
        transport.stop()
        tk.expect(!transport.metronomeEnabled, "metronome still off after stop")

        // AppStore play path: default metronome is off; play/stop must leave isPlaying clean
        // and not require the (internal) toggle to run.
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.startEngineIfNeeded()
        store.project.tracks[0].clips = [clip]
        store.scrubPlayhead(to: 0)
        store.startPlayback()
        tk.expect(store.isPlaying, "AppStore play starts with default metronome off")
        store.stopPlayback()
        tk.expect(!store.isPlaying, "AppStore stop after play with metronome default")
    }

    // MARK: - AC16 instrument change

    tk.suite("AC16: instrument change persists save/open; notes untouched") {
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let n1 = Note(startBeat: 0.5, lengthBeats: 1.0, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 2.0, lengthBeats: 0.75, pitch: 67, velocity: 88)
        let clip = Clip(kind: .midi, name: "AC16", startBeat: 0, lengthBeats: 8,
                        midiNotes: [n1, n2])
        store.project.tracks[0].clips = [clip]
        let tid = store.project.tracks[0].id
        let beforeNotes = store.project.tracks[0].clips[0].midiNotes!

        // Rename so selectPreset does not also rewrite the track name (default "Piano" would).
        store.renameTrack(tid, to: "Keys")
        let instBefore = store.project.track(id: tid)?.instrument
        tk.expect(instBefore != nil, "seed track has an instrument")

        guard let target = SoundBank.presets.first(where: {
            $0.program != instBefore?.program || $0.bankMSB != instBefore?.bankMSB
        }) ?? SoundBank.presets.last else {
            tk.expect(false, "curated presets available for instrument change")
            return
        }
        store.selectPreset(target, for: tid)
        let instAfter = store.project.track(id: tid)?.instrument
        tk.expectEqual(instAfter?.program, target.program, "instrument program set")
        tk.expectEqual(instAfter?.bankMSB, target.bankMSB, "instrument bankMSB set")
        tk.expectEqual(instAfter?.bankLSB, target.bankLSB, "instrument bankLSB set")

        // Notes completely unchanged.
        let notesAfter = store.project.tracks[0].clips[0].midiNotes!
        tk.expectEqual(notesAfter.count, beforeNotes.count, "note count unchanged by instrument")
        for i in beforeNotes.indices {
            tk.expectEqual(notesAfter[i].id, beforeNotes[i].id, "note \(i) id unchanged")
            tk.expectEqual(notesAfter[i].pitch, beforeNotes[i].pitch, "note \(i) pitch unchanged")
            tk.expectEqual(notesAfter[i].startBeat, beforeNotes[i].startBeat,
                           "note \(i) start unchanged")
            tk.expectEqual(notesAfter[i].lengthBeats, beforeNotes[i].lengthBeats,
                           "note \(i) length unchanged")
            tk.expectEqual(notesAfter[i].velocity, beforeNotes[i].velocity,
                           "note \(i) velocity unchanged")
        }
        tk.expectEqual(store.project.track(id: tid)?.name, "Keys",
                       "user track name kept when changing instrument")

        // Save / open round trip preserves instrument and notes.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC16-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("AC16.verse")
        try ProjectPackage.write(store.project, to: pkg, mediaSourceDir: nil)
        let back = try ProjectPackage.read(pkg)
        let backTrack = back.tracks.first(where: { $0.id == tid })
        tk.expect(backTrack != nil, "track present after open")
        tk.expectEqual(backTrack?.instrument?.program, target.program,
                       "instrument program survives save/open")
        tk.expectEqual(backTrack?.instrument?.bankMSB, target.bankMSB,
                       "instrument bankMSB survives save/open")
        tk.expectEqual(backTrack?.instrument?.bankLSB, target.bankLSB,
                       "instrument bankLSB survives save/open")
        let backNotes = backTrack?.clips.first?.midiNotes ?? []
        tk.expectEqual(backNotes.count, 2, "notes survive save/open")
        tk.expectEqual(backNotes[0].pitch, 60, "note 0 pitch after open")
        tk.expectEqual(backNotes[1].pitch, 67, "note 1 pitch after open")
        tk.expectEqual(backNotes[0].id, n1.id, "note 0 id after open")
        tk.expectEqual(backNotes[1].id, n2.id, "note 1 id after open")
    }

    // MARK: - AC17 track effects / inserts

    tk.suite("AC17: built-in effect into Track.inserts under verse.builtin; clear removes only that") {
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        let tid = store.project.tracks[0].id
        // Hosted / foreign insert must survive clearing the built-in.
        let foreign = AudioUnitRef(
            type: "aufx", subtype: "host", manufacturer: "com.example.thirdparty",
            name: "Hosted FX", stateBlob: Data([0xAA]))
        if let i = store.project.trackIndex(id: tid) {
            store.project.tracks[i].inserts = [foreign]
        }
        tk.expectEqual(store.project.track(id: tid)?.inserts.count, 1,
                       "foreign insert present before built-in")

        store.setEffect(.reverb, tid)
        tk.expectEqual(store.effect(for: tid), .reverb, "effect(for:) reports reverb")
        let insertsAfter = store.project.track(id: tid)?.inserts ?? []
        let builtinTag = AppStore.builtInEffectManufacturer
        let builtins = insertsAfter.filter { $0.manufacturer == builtinTag }
        tk.expectEqual(builtins.count, 1, "exactly one verse.builtin insert after set")
        tk.expectEqual(builtins.first?.subtype, VerseAudioEngine.BuiltInEffect.reverb.rawValue,
                       "builtin subtype is reverb")
        tk.expectEqual(builtins.first?.manufacturer, builtinTag,
                       "builtin manufacturer tag is verse.builtin")
        tk.expect(insertsAfter.contains(where: {
            $0.manufacturer == foreign.manufacturer && $0.subtype == foreign.subtype
        }), "foreign insert still present after setEffect")
        tk.expectEqual(AppStore.builtInEffect(fromInserts: insertsAfter), .reverb,
                       "builtInEffect(fromInserts:) reads reverb")

        // Save / open round trip.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("AC17.verse")
        try ProjectPackage.write(store.project, to: pkg, mediaSourceDir: nil)
        let back = try ProjectPackage.read(pkg)
        let backInserts = back.tracks.first(where: { $0.id == tid })?.inserts ?? []
        tk.expectEqual(AppStore.builtInEffect(fromInserts: backInserts), .reverb,
                       "built-in effect survives save/open")
        tk.expect(backInserts.contains(where: { $0.manufacturer == builtinTag }),
                  "verse.builtin entry present after open")
        tk.expect(backInserts.contains(where: { $0.manufacturer == foreign.manufacturer }),
                  "foreign insert survives save/open alongside builtin")

        // Clear: removes only the built-in entry.
        store.setEffect(.none, tid)
        tk.expectEqual(store.effect(for: tid), .none, "effect(for:) reports none after clear")
        let afterClear = store.project.track(id: tid)?.inserts ?? []
        tk.expect(!afterClear.contains(where: { $0.manufacturer == builtinTag }),
                  "clear removes verse.builtin entry")
        tk.expectEqual(afterClear.count, 1, "only foreign insert remains after clear")
        tk.expectEqual(afterClear.first?.manufacturer, foreign.manufacturer,
                       "remaining insert is the foreign one")
        tk.expectEqual(AppStore.builtInEffect(fromInserts: afterClear), .none,
                       "builtInEffect reads none after clear")
    }

    // MARK: - AC10 undo/redo deep stack + redo invalidation

    tk.suite("AC10: undo/redo deep stack and redo invalidation") {
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Baseline (no edits yet).
        var fingerprints: [String] = [projectFingerprint(store.project)]
        let baselineTempo = store.project.tempoBPM
        let baselineTrackCount = store.project.tracks.count
        let baselineName = store.project.tracks[0].name
        let seedTrackID = store.project.tracks[0].id

        // 1. Add instrument track
        store.addInstrumentTrack()
        tk.expectEqual(store.project.tracks.count, baselineTrackCount + 1, "edit 1: track added")
        fingerprints.append(projectFingerprint(store.project))

        // 2. Set tempo
        store.setTempo(140)
        tk.expectEqual(store.project.tempoBPM, 140, "edit 2: tempo 140")
        fingerprints.append(projectFingerprint(store.project))

        // 3. Set key
        store.setKey(tonic: .D, mode: .minor)
        tk.expectEqual(store.project.key?.tonic, .D, "edit 3: key tonic D")
        tk.expectEqual(store.project.key?.mode, .minor, "edit 3: key mode minor")
        fingerprints.append(projectFingerprint(store.project))

        // 4. Rename seed track
        store.renameTrack(seedTrackID, to: "Lead")
        tk.expectEqual(store.project.track(id: seedTrackID)?.name, "Lead", "edit 4: renamed Lead")
        fingerprints.append(projectFingerprint(store.project))

        // 5. Track colour
        store.setTrackColorIndex(3, seedTrackID)
        tk.expectEqual(store.project.track(id: seedTrackID)?.colorIndex, 3, "edit 5: colour 3")
        fingerprints.append(projectFingerprint(store.project))

        // 6. Add audio track (another discrete undo entry; no out-of-band project mutation)
        store.addAudioTrack()
        tk.expectEqual(store.project.tracks.count, baselineTrackCount + 2, "edit 6: audio track added")
        tk.expectEqual(store.project.tracks.last?.kind, .audio, "edit 6: last track is audio")
        fingerprints.append(projectFingerprint(store.project))

        // Six discrete undo-recording edits (add instrument through add audio).
        // fingerprints[0] = baseline, fingerprints[1...6] = after each edit.
        tk.expectEqual(fingerprints.count, 7, "baseline + 6 edit snapshots")
        tk.expect(store.canUndo, "can undo after 6 edits")
        tk.expect(!store.canRedo, "no redo at top of stack")

        // Undo all the way back, checking state at each boundary.
        for step in stride(from: 6, through: 1, by: -1) {
            tk.expect(store.canUndo, "can undo at depth \(step)")
            store.undo()
            let got = projectFingerprint(store.project)
            tk.expectEqual(got, fingerprints[step - 1],
                           "after undo from \(step): state matches snapshot \(step - 1)")
        }
        tk.expect(!store.canUndo, "stack empty after undoing all 6")
        tk.expect(store.canRedo, "can redo after full undo")
        tk.expectEqual(store.project.tempoBPM, baselineTempo, "full undo restores baseline tempo")
        tk.expectEqual(store.project.tracks.count, baselineTrackCount, "full undo restores track count")
        tk.expectEqual(store.project.tracks[0].name, baselineName, "full undo restores seed name")

        // Redo all the way forward.
        for step in 1...6 {
            tk.expect(store.canRedo, "can redo toward step \(step)")
            store.redo()
            let got = projectFingerprint(store.project)
            tk.expectEqual(got, fingerprints[step],
                           "after redo to \(step): state matches snapshot \(step)")
        }
        tk.expect(!store.canRedo, "no further redo after full redo")
        tk.expect(store.canUndo, "can undo again after full redo")
        tk.expectEqual(store.project.tempoBPM, 140, "full redo restores tempo 140")
        tk.expectEqual(store.project.tracks.count, baselineTrackCount + 2,
                       "full redo restores both added tracks")
        tk.expectEqual(store.project.track(id: seedTrackID)?.name, "Lead",
                       "full redo restores rename")
        tk.expectEqual(store.project.track(id: seedTrackID)?.colorIndex, 3,
                       "full redo restores colour")

        // NEW edit after an undo invalidates redo.
        store.undo()
        tk.expect(store.canRedo, "redo available after one undo from top")
        store.setTempo(199)
        tk.expectEqual(store.project.tempoBPM, 199, "new edit applied after undo")
        tk.expect(!store.canRedo, "new edit after undo clears redo (canRedo == false)")
        tk.expect(store.canUndo, "new edit is itself undoable")
    }

    // MARK: - AC13 tempo clamp, undo, redo

    tk.suite("AC13: setTempo clamps, one undo entry, undo/redo") {
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = store.project.tempoBPM
        tk.expect(!store.canUndo, "fresh store has empty undo before tempo")

        // Documented AppStore clamp: max(20, min(300, bpm)).
        store.setTempo(10)
        tk.expectEqual(store.project.tempoBPM, 20, "below-range tempo clamps to 20")
        tk.expectEqual(store.undoName, "Set Tempo", "setTempo labels undo")
        // Exactly one entry so far.
        store.undo()
        tk.expectEqual(store.project.tempoBPM, original, "undo restores pre-tempo")
        tk.expect(!store.canUndo, "only one undo entry was recorded for setTempo")
        store.redo()
        tk.expectEqual(store.project.tempoBPM, 20, "redo restores clamped low tempo")

        store.setTempo(999)
        tk.expectEqual(store.project.tempoBPM, 300, "above-range tempo clamps to 300")
        store.undo()
        tk.expectEqual(store.project.tempoBPM, 20, "undo after high clamp restores previous (20)")
        store.redo()
        tk.expectEqual(store.project.tempoBPM, 300, "redo restores clamped high tempo")

        // In-range value is stored exactly.
        store.setTempo(128)
        tk.expectEqual(store.project.tempoBPM, 128, "in-range tempo stored exactly")
        store.undo()
        tk.expectEqual(store.project.tempoBPM, 300, "undo of 128 restores 300")
        store.redo()
        tk.expectEqual(store.project.tempoBPM, 128, "redo of 128 restores 128")

        // Boundary values.
        store.setTempo(20)
        tk.expectEqual(store.project.tempoBPM, 20, "floor 20 accepted")
        store.setTempo(300)
        tk.expectEqual(store.project.tempoBPM, 300, "ceiling 300 accepted")
    }

    // MARK: - AC14 time signature does not move clips or notes

    tk.suite("AC14: time signature change leaves clip and note beat positions") {
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two clips with notes at non-trivial beat positions.
        let n1 = Note(startBeat: 1.5, lengthBeats: 0.75, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 3.25, lengthBeats: 0.5, pitch: 64, velocity: 90)
        let n3 = Note(startBeat: 0.0, lengthBeats: 2.0, pitch: 48, velocity: 80)
        let c1 = Clip(kind: .midi, name: "A", startBeat: 2.0, lengthBeats: 8.0, midiNotes: [n1, n2])
        let c2 = Clip(kind: .midi, name: "B", startBeat: 16.5, lengthBeats: 4.0, midiNotes: [n3])
        store.project.tracks[0].clips = [c1, c2]
        store.addInstrumentTrack()
        let c3 = Clip(kind: .midi, name: "C", startBeat: 7.0, lengthBeats: 2.0,
                      midiNotes: [Note(startBeat: 0.25, lengthBeats: 1.0, pitch: 72, velocity: 100)])
        store.project.tracks[1].clips = [c3]

        // Snapshot beat positions before the change.
        struct NoteSnap {
            let start: Double
            let len: Double
            let pitch: Int
        }
        struct BeatSnap {
            let clipStart: Double
            let clipLen: Double
            let notes: [NoteSnap]
        }
        func snap(_ project: Project) -> [[BeatSnap]] {
            project.tracks.map { track in
                track.clips.map { clip in
                    BeatSnap(
                        clipStart: clip.startBeat,
                        clipLen: clip.lengthBeats,
                        notes: (clip.midiNotes ?? []).map {
                            NoteSnap(start: $0.startBeat, len: $0.lengthBeats, pitch: $0.pitch)
                        }
                    )
                }
            }
        }
        let before = snap(store.project)
        tk.expectEqual(store.project.timeSignature.num, 4, "starts in 4/4")
        tk.expectEqual(store.project.timeSignature.den, 4, "starts in 4/4 den")

        // Product path that changes time signature: AI setTimeSignature (no free-form UI setter).
        let fp = store.project.structuralFingerprint
        let reply = """
        {"versePatch":{"schema":"verse-patch","version":1,"fingerprint":"\(fp)",
          "summary":"AC14 time signature",
          "ops":[{"op":"setTimeSignature","num":3,"den":8}]}}
        """
        store.copilotReply = reply
        store.applyCopilotReply()
        tk.expect(store.pendingCopilotPreview != nil, "time signature patch previews")
        store.commitCopilotPreview()
        tk.expectEqual(store.project.timeSignature.num, 3, "time signature num is 3")
        tk.expectEqual(store.project.timeSignature.den, 8, "time signature den is 8")

        let after = snap(store.project)
        tk.expectEqual(after.count, before.count, "track count unchanged by time signature")
        for ti in before.indices {
            tk.expectEqual(after[ti].count, before[ti].count,
                           "track \(ti) clip count unchanged")
            for ci in before[ti].indices {
                tk.expectEqual(after[ti][ci].clipStart, before[ti][ci].clipStart,
                               "track \(ti) clip \(ci) startBeat unchanged")
                tk.expectEqual(after[ti][ci].clipLen, before[ti][ci].clipLen,
                               "track \(ti) clip \(ci) lengthBeats unchanged")
                tk.expectEqual(after[ti][ci].notes.count, before[ti][ci].notes.count,
                               "track \(ti) clip \(ci) note count unchanged")
                for ni in before[ti][ci].notes.indices {
                    let a = after[ti][ci].notes[ni]
                    let b = before[ti][ci].notes[ni]
                    tk.expectEqual(a.start, b.start,
                                   "track \(ti) clip \(ci) note \(ni) startBeat unchanged")
                    tk.expectEqual(a.len, b.len,
                                   "track \(ti) clip \(ci) note \(ni) lengthBeats unchanged")
                    tk.expectEqual(a.pitch, b.pitch,
                                   "track \(ti) clip \(ci) note \(ni) pitch unchanged")
                }
            }
        }
    }

    // MARK: - AC18 mix extremes, mute+solo

    tk.suite("AC18: volume/pan extremes clamped, no NaN; mute+solo same track is muted") {
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tid = store.project.tracks[0].id
        store.startEngineIfNeeded()

        // Legal extremes: accepted and finite.
        store.setVolume(0, tid)
        var vol = store.project.track(id: tid)!.volume
        tk.expectEqual(vol, 0, "volume 0 accepted")
        tk.expect(vol.isFinite && !vol.isNaN, "volume 0 is finite, not NaN")

        store.setVolume(1, tid)
        vol = store.project.track(id: tid)!.volume
        tk.expectEqual(vol, 1, "volume 1 accepted")
        tk.expect(vol.isFinite && !vol.isNaN, "volume 1 is finite, not NaN")

        store.setPan(-1, tid)
        var pan = store.project.track(id: tid)!.pan
        tk.expectEqual(pan, -1, "pan -1 accepted")
        tk.expect(pan.isFinite && !pan.isNaN, "pan -1 is finite, not NaN")

        store.setPan(1, tid)
        pan = store.project.track(id: tid)!.pan
        tk.expectEqual(pan, 1, "pan +1 accepted")
        tk.expect(pan.isFinite && !pan.isNaN, "pan +1 is finite, not NaN")

        // Out-of-range: documented track ranges are volume 0…1 and pan -1…1.
        // setVolume / setPan must leave the model in those ranges (no NaN, no wild values).
        store.setVolume(-0.5, tid)
        vol = store.project.track(id: tid)!.volume
        tk.expect(vol.isFinite && !vol.isNaN, "out-of-range low volume is not NaN")
        tk.expect(vol >= 0 && vol <= 1,
                  "out-of-range low volume stays clamped in 0…1 (got \(vol))")

        store.setVolume(1.5, tid)
        vol = store.project.track(id: tid)!.volume
        tk.expect(vol.isFinite && !vol.isNaN, "out-of-range high volume is not NaN")
        tk.expect(vol >= 0 && vol <= 1,
                  "out-of-range high volume stays clamped in 0…1 (got \(vol))")

        store.setPan(-2, tid)
        pan = store.project.track(id: tid)!.pan
        tk.expect(pan.isFinite && !pan.isNaN, "out-of-range low pan is not NaN")
        tk.expect(pan >= -1 && pan <= 1,
                  "out-of-range low pan stays clamped in -1…1 (got \(pan))")

        store.setPan(2, tid)
        pan = store.project.track(id: tid)!.pan
        tk.expect(pan.isFinite && !pan.isNaN, "out-of-range high pan is not NaN")
        tk.expect(pan >= -1 && pan <= 1,
                  "out-of-range high pan stays clamped in -1…1 (got \(pan))")

        // Engine path clamps independently (standalone engine; AppStore.engine is internal).
        let engine = VerseAudioEngine()
        var engineProject = Project.newUntitled()
        engineProject.tracks[0].id = tid
        engine.configure(with: engineProject)
        engine.setTrackVolume(5, trackID: tid, muted: false)
        engine.setTrackPan(3, trackID: tid)
        tk.expect(engine.trackExists(tid), "engine track still present after extreme mix")

        // Mute and solo on the SAME track resolves to muted.
        // Effective mute (AppStore.applyEffectiveMix): mute || (anySolo && !solo).
        // With mute=true and solo=true on one track: mute is true, so effectively muted.
        if let i = store.project.trackIndex(id: tid) {
            store.project.tracks[i].mute = true
            store.project.tracks[i].solo = true
            store.project.tracks[i].volume = 0.9
        }
        let t = store.project.track(id: tid)!
        tk.expect(t.mute && t.solo, "same track has both mute and solo on")
        let anySolo = store.project.anySolo
        let effectiveMute = t.mute || (anySolo && !t.solo)
        tk.expect(effectiveMute,
                  "mute+solo on same track resolves to muted (effectiveMute)")

        // Engine applyMix zeros when track.mute is true (solo is handled only in AppStore).
        engine.applyMix(t)
        engine.setTrackVolume(t.volume, trackID: tid, muted: effectiveMute)
        tk.expect(engine.trackExists(tid),
                  "engine still has track after mute+solo effective mix")
    }

    // MARK: - AC20 multi-clip select + delete + single undo restores all

    tk.suite("AC20: multi-clip delete is one undo that restores all") {
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = Clip(kind: .midi, name: "A", startBeat: 0, lengthBeats: 4,
                     midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        let b = Clip(kind: .midi, name: "B", startBeat: 4, lengthBeats: 4,
                     midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 62, velocity: 100)])
        let c = Clip(kind: .midi, name: "C", startBeat: 8, lengthBeats: 4,
                     midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 64, velocity: 100)])
        store.project.tracks[0].clips = [a, b, c]
        let ids = [a.id, b.id, c.id]
        store.selectedClipIDs = Set(ids)

        tk.expectEqual(store.project.tracks[0].clips.count, 3, "three clips before delete")
        tk.expectEqual(store.selectedClipIDs.count, 3, "three clips selected")
        tk.expect(!store.canUndo, "no undo before multi-delete")

        store.arrangementDeleteClips(ids: ids)
        tk.expectEqual(store.project.tracks[0].clips.count, 0, "all selected clips deleted")
        tk.expectEqual(store.undoName, "Delete Clips", "multi-delete labels as Delete Clips")
        // One undo entry only: undoing once empties the stack.
        tk.expect(store.canUndo, "delete recorded undo")
        store.undo()
        tk.expectEqual(store.project.tracks[0].clips.count, 3,
                       "single undo restores all three clips")
        let restoredIDs = Set(store.project.tracks[0].clips.map(\.id))
        tk.expectEqual(restoredIDs, Set(ids), "restored clip ids match the deleted set")
        tk.expectEqual(store.project.tracks[0].clips.map(\.name).sorted(),
                       ["A", "B", "C"], "restored clip names intact")
        tk.expect(!store.canUndo, "single undo emptied the stack (one entry, not three)")
        tk.expect(store.canRedo, "can redo the multi-delete")
        store.redo()
        tk.expectEqual(store.project.tracks[0].clips.count, 0, "redo removes all three again")
    }

    // MARK: - AC11 ProjectPackage round-trip of key model fields

    tk.suite("AC11: ProjectPackage save/open round-trips tracks, notes, colour, mediaStart, tempo") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let noteA = Note(startBeat: 0.5, lengthBeats: 1.0, pitch: 67, velocity: 110)
        let noteB = Note(startBeat: 2.0, lengthBeats: 0.5, pitch: 71, velocity: 95)
        let midiClip = Clip(
            kind: .midi, name: "Hook", startBeat: 4, lengthBeats: 8,
            mediaStartSeconds: 0,
            midiNotes: [noteA, noteB])
        let audioClip = Clip(
            kind: .audio, name: "Take", startBeat: 0, lengthBeats: 16,
            mediaFile: "take-ac11.caf", mediaStartSeconds: 1.25)
        let inst = Track(
            kind: .instrument, name: "Keys",
            volume: 0.7, pan: -0.25, mute: false, solo: false,
            colorIndex: 5,
            instrument: .grandPiano,
            clips: [midiClip])
        let audio = Track(
            kind: .audio, name: "Vox",
            volume: 0.9, pan: 0.1,
            colorIndex: 2,
            clips: [audioClip])
        let project = Project(
            title: "AC11 Round Trip",
            tempoBPM: 132,
            tracks: [inst, audio],
            masterVolume: 0.8)
        let projectID = project.id
        let instID = inst.id
        let audioID = audio.id
        let midiClipID = midiClip.id
        let audioClipID = audioClip.id
        let noteAID = noteA.id
        let noteBID = noteB.id

        let pkg = root.appendingPathComponent("AC11.verse")
        try ProjectPackage.write(project, to: pkg, mediaSourceDir: nil)
        let back = try ProjectPackage.read(pkg)

        tk.expectEqual(back.id, projectID, "project id round-trips")
        tk.expectEqual(back.title, "AC11 Round Trip", "title round-trips")
        tk.expectEqual(back.tempoBPM, 132, "tempo round-trips")
        tk.expectEqual(back.tracks.count, 2, "two tracks round-trip")

        let backInst = back.tracks.first(where: { $0.id == instID })
        let backAudio = back.tracks.first(where: { $0.id == audioID })
        tk.expect(backInst != nil, "instrument track present")
        tk.expect(backAudio != nil, "audio track present")
        tk.expectEqual(backInst?.name, "Keys", "instrument name")
        tk.expectEqual(backInst?.colorIndex, 5, "instrument colorIndex")
        tk.expectEqual(backAudio?.name, "Vox", "audio name")
        tk.expectEqual(backAudio?.colorIndex, 2, "audio colorIndex")

        let backMidi = backInst?.clips.first(where: { $0.id == midiClipID })
        tk.expect(backMidi != nil, "midi clip present")
        tk.expectEqual(backMidi?.startBeat, 4, "midi clip startBeat")
        tk.expectEqual(backMidi?.lengthBeats, 8, "midi clip lengthBeats")
        tk.expectEqual(backMidi?.mediaStartSeconds, 0, "midi mediaStartSeconds default")
        tk.expectEqual(backMidi?.midiNotes?.count, 2, "two notes round-trip")
        let backNotes = backMidi?.midiNotes ?? []
        let bnA = backNotes.first(where: { $0.id == noteAID })
        let bnB = backNotes.first(where: { $0.id == noteBID })
        tk.expectEqual(bnA?.pitch, 67, "note A pitch")
        tk.expectEqual(bnA?.startBeat, 0.5, "note A startBeat")
        tk.expectEqual(bnA?.velocity, 110, "note A velocity")
        tk.expectEqual(bnB?.pitch, 71, "note B pitch")
        tk.expectEqual(bnB?.startBeat, 2.0, "note B startBeat")

        let backAudClip = backAudio?.clips.first(where: { $0.id == audioClipID })
        tk.expect(backAudClip != nil, "audio clip present")
        tk.expectEqual(backAudClip?.mediaFile, "take-ac11.caf", "audio mediaFile")
        tk.expectEqual(backAudClip?.mediaStartSeconds, 1.25, "audio mediaStartSeconds")
        tk.expectEqual(backAudClip?.startBeat, 0, "audio clip startBeat")
        tk.expectEqual(backAudClip?.lengthBeats, 16, "audio clip lengthBeats")
    }

    // MARK: - AC5 moveClipToTrack

    tk.suite("AC5: moveClipToTrack preserves notes; rejects kind mismatch and unknown track") {
        // Model path: MIDI clip with several notes, two instrument tracks + one audio track.
        var project = Project.newUntitled()
        project.tracks.append(Track(kind: .instrument, name: "Lead", instrument: .grandPiano))
        project.tracks.append(Track(kind: .audio, name: "Vox"))
        let n1 = Note(startBeat: 0.0, lengthBeats: 1.0, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 1.5, lengthBeats: 0.5, pitch: 64, velocity: 90)
        let n3 = Note(startBeat: 2.25, lengthBeats: 1.75, pitch: 67, velocity: 80)
        let midi = Clip(kind: .midi, name: "Phrase", startBeat: 4, lengthBeats: 8,
                        midiNotes: [n1, n2, n3])
        let audio = Clip(kind: .audio, name: "Take", startBeat: 0, lengthBeats: 4,
                         mediaFile: "take-ac5.caf")
        project.tracks[0].clips = [midi]
        project.tracks[2].clips = [audio]
        let midiID = midi.id
        let audioID = audio.id
        let beforeNotes = [n1, n2, n3]

        // Happy path: MIDI → other instrument track; notes and clip id fully preserved.
        try project.moveClip(id: midiID, toTrackIndex: 1, startBeat: 12)
        tk.expectEqual(project.tracks[0].clips.count, 0, "MIDI left source instrument track")
        tk.expectEqual(project.tracks[1].clips.count, 1, "MIDI on dest instrument track")
        let moved = project.tracks[1].clips[0]
        tk.expectEqual(moved.id, midiID, "clip id preserved on move")
        tk.expectEqual(moved.startBeat, 12, "startBeat updated on cross-track move")
        tk.expectEqual(moved.lengthBeats, 8, "lengthBeats unchanged on move")
        let afterNotes = moved.midiNotes ?? []
        tk.expectEqual(afterNotes.count, beforeNotes.count, "note count preserved")
        for i in beforeNotes.indices {
            tk.expectEqual(afterNotes[i].id, beforeNotes[i].id, "note \(i) id preserved")
            tk.expectEqual(afterNotes[i].pitch, beforeNotes[i].pitch, "note \(i) pitch preserved")
            tk.expectEqual(afterNotes[i].startBeat, beforeNotes[i].startBeat,
                           "note \(i) startBeat preserved")
            tk.expectEqual(afterNotes[i].lengthBeats, beforeNotes[i].lengthBeats,
                           "note \(i) lengthBeats preserved")
            tk.expectEqual(afterNotes[i].velocity, beforeNotes[i].velocity,
                           "note \(i) velocity preserved")
        }

        // Incompatible: MIDI onto audio track — throw, no partial mutation.
        let fingerprintBeforeReject = projectFingerprint(project)
        tk.expectThrows("MIDI onto audio track rejected") {
            try project.moveClip(id: midiID, toTrackIndex: 2, startBeat: 0)
        }
        tk.expectEqual(projectFingerprint(project), fingerprintBeforeReject,
                       "MIDI→audio reject leaves project unchanged")
        tk.expectEqual(project.tracks[1].clips.count, 1, "MIDI still on instrument after reject")
        tk.expectEqual(project.tracks[2].clips.count, 1, "audio track still only has audio clip")

        // Incompatible: audio onto instrument track.
        let beforeAudioReject = projectFingerprint(project)
        tk.expectThrows("audio onto instrument track rejected") {
            try project.moveClip(id: audioID, toTrackIndex: 0, startBeat: 0)
        }
        tk.expectEqual(projectFingerprint(project), beforeAudioReject,
                       "audio→instrument reject leaves project unchanged")
        tk.expectEqual(project.tracks[2].clips[0].id, audioID, "audio clip id stable after reject")

        // Unknown track index (out of bounds) — trackNotFound, no mutation.
        let beforeUnknown = projectFingerprint(project)
        tk.expectThrows("unknown track index rejected") {
            try project.moveClip(id: midiID, toTrackIndex: 99, startBeat: 0)
        }
        tk.expectEqual(projectFingerprint(project), beforeUnknown,
                       "unknown track reject leaves project unchanged")
        tk.expectEqual(project.tracks[1].clips[0].id, midiID, "clip still on dest after unknown track")

        // AppStore path: arrangementMoveClips moves MIDI to the other instrument track
        // without losing notes; kind mismatch is a whole-update no-op.
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.addInstrumentTrack()
        store.addAudioTrack()
        let sn1 = Note(startBeat: 0.25, lengthBeats: 1.0, pitch: 62, velocity: 110)
        let sn2 = Note(startBeat: 2.0, lengthBeats: 0.75, pitch: 69, velocity: 95)
        let sClip = Clip(kind: .midi, name: "StorePhrase", startBeat: 2, lengthBeats: 6,
                         midiNotes: [sn1, sn2])
        store.project.tracks[0].clips = [sClip]
        let sID = sClip.id
        let destInst = 1
        store.beginArrangementGesture(name: "Move Clip")
        store.arrangementMoveClips([(id: sID, startBeat: 8, trackIndex: destInst)])
        store.endArrangementGesture()
        tk.expectEqual(store.project.tracks[0].clips.count, 0, "AppStore: left source track")
        tk.expectEqual(store.project.tracks[destInst].clips.count, 1, "AppStore: on dest track")
        let storeMoved = store.project.tracks[destInst].clips[0]
        tk.expectEqual(storeMoved.id, sID, "AppStore: clip id preserved")
        tk.expectEqual(storeMoved.midiNotes?.count, 2, "AppStore: both notes present")
        tk.expectEqual(storeMoved.midiNotes?[0].pitch, 62, "AppStore: note 0 pitch")
        tk.expectEqual(storeMoved.midiNotes?[0].startBeat, 0.25, "AppStore: note 0 start")
        tk.expectEqual(storeMoved.midiNotes?[0].lengthBeats, 1.0, "AppStore: note 0 length")
        tk.expectEqual(storeMoved.midiNotes?[0].velocity, 110, "AppStore: note 0 velocity")
        tk.expectEqual(storeMoved.midiNotes?[1].id, sn2.id, "AppStore: note 1 id preserved")

        // Kind mismatch via AppStore: whole update rejected (project fingerprint stable).
        let fpBeforeKind = projectFingerprint(store.project)
        store.beginArrangementGesture(name: "Move Clip")
        store.arrangementMoveClips([(id: sID, startBeat: 0, trackIndex: 2)]) // audio track
        store.endArrangementGesture()
        tk.expectEqual(projectFingerprint(store.project), fpBeforeKind,
                       "AppStore: kind mismatch leaves project unchanged")
        tk.expectEqual(store.project.tracks[destInst].clips[0].id, sID,
                       "AppStore: clip stayed on instrument after kind reject")
    }

    // MARK: - AC6 resizeClip

    tk.suite("AC6: resizeClip preserves interior notes; rejects 0/negative; never moves start") {
        var project = Project.newUntitled()
        let nInside = Note(startBeat: 0.5, lengthBeats: 1.0, pitch: 60, velocity: 100)
        let nAlsoInside = Note(startBeat: 2.0, lengthBeats: 0.5, pitch: 64, velocity: 90)
        let nOutsideAfterShorten = Note(startBeat: 5.0, lengthBeats: 1.0, pitch: 67, velocity: 80)
        let clip = Clip(kind: .midi, name: "ResizeMe", startBeat: 4.0, lengthBeats: 8.0,
                        midiNotes: [nInside, nAlsoInside, nOutsideAfterShorten])
        project.tracks[0].clips = [clip]
        let clipID = clip.id
        let originalStart = clip.startBeat

        // Lengthen: startBeat fixed; notes that were inside remain identical.
        try project.resizeClip(id: clipID, toLengthBeats: 12)
        let longer = project.tracks[0].clips[0]
        tk.expectEqual(longer.startBeat, originalStart, "lengthen does not move startBeat")
        tk.expectEqual(longer.lengthBeats, 12, "lengthen sets lengthBeats")
        tk.expectEqual(longer.midiNotes?.count, 3, "lengthen keeps all notes")
        for (i, expected) in [nInside, nAlsoInside, nOutsideAfterShorten].enumerated() {
            let got = longer.midiNotes![i]
            tk.expectEqual(got.id, expected.id, "lengthen note \(i) id")
            tk.expectEqual(got.pitch, expected.pitch, "lengthen note \(i) pitch")
            tk.expectEqual(got.startBeat, expected.startBeat, "lengthen note \(i) start")
            tk.expectEqual(got.lengthBeats, expected.lengthBeats, "lengthen note \(i) length")
            tk.expectEqual(got.velocity, expected.velocity, "lengthen note \(i) velocity")
        }

        // Shorten so nOutsideAfterShorten is past the new end: notes still inside the new
        // length (startBeat < newLen) keep their payload.
        try project.resizeClip(id: clipID, toLengthBeats: 4)
        let shorter = project.tracks[0].clips[0]
        tk.expectEqual(shorter.startBeat, originalStart, "shorten does not move startBeat")
        tk.expectEqual(shorter.lengthBeats, 4, "shorten sets lengthBeats")
        let notesAfterShorten = shorter.midiNotes ?? []
        let interior = notesAfterShorten.filter { $0.startBeat < 4 }
        tk.expect(interior.contains(where: { $0.id == nInside.id }),
                  "note inside new length (nInside) still present")
        tk.expect(interior.contains(where: { $0.id == nAlsoInside.id }),
                  "note inside new length (nAlsoInside) still present")
        if let kept = notesAfterShorten.first(where: { $0.id == nInside.id }) {
            tk.expectEqual(kept.pitch, 60, "interior note pitch after shorten")
            tk.expectEqual(kept.startBeat, 0.5, "interior note start after shorten")
            tk.expectEqual(kept.lengthBeats, 1.0, "interior note length after shorten")
            tk.expectEqual(kept.velocity, 100, "interior note velocity after shorten")
        }

        // Zero / negative rejected; start and length unchanged by the reject.
        let lenBeforeReject = project.tracks[0].clips[0].lengthBeats
        let startBeforeReject = project.tracks[0].clips[0].startBeat
        tk.expectThrows("resize length 0 rejected") {
            try project.resizeClip(id: clipID, toLengthBeats: 0)
        }
        tk.expectThrows("resize negative length rejected") {
            try project.resizeClip(id: clipID, toLengthBeats: -1)
        }
        tk.expectEqual(project.tracks[0].clips[0].lengthBeats, lenBeforeReject,
                       "failed resize leaves lengthBeats")
        tk.expectEqual(project.tracks[0].clips[0].startBeat, startBeforeReject,
                       "failed resize leaves startBeat")

        // AppStore continuous resize: begin gesture, resize, end; startBeat fixed.
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aNote = Note(startBeat: 0, lengthBeats: 1, pitch: 72, velocity: 100)
        let aClip = Clip(kind: .midi, name: "AS", startBeat: 2, lengthBeats: 4,
                         midiNotes: [aNote])
        store.project.tracks[0].clips = [aClip]
        store.beginArrangementGesture(name: "Resize Clip")
        store.arrangementResizeClip(id: aClip.id, toLengthBeats: 7)
        store.endArrangementGesture()
        tk.expectEqual(store.project.tracks[0].clips[0].lengthBeats, 7,
                       "AppStore resize sets length")
        tk.expectEqual(store.project.tracks[0].clips[0].startBeat, 2,
                       "AppStore resize never moves startBeat")
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?[0].pitch, 72,
                       "AppStore resize preserves note")

        // AppStore: zero length mid-drag does not mutate (model reject swallowed).
        store.beginArrangementGesture(name: "Resize Clip")
        store.arrangementResizeClip(id: aClip.id, toLengthBeats: 0)
        store.endArrangementGesture()
        tk.expectEqual(store.project.tracks[0].clips[0].lengthBeats, 7,
                       "AppStore zero resize leaves prior length")
        tk.expectEqual(store.project.tracks[0].clips[0].startBeat, 2,
                       "AppStore zero resize leaves startBeat")
    }

    // MARK: - Non-destructive clip trim (load-bearing contract)

    /// Clip.lengthBeats is a playback WINDOW over note data, not a container that owns
    /// or bounds the stored notes. Shortening a clip hides notes past the new end;
    /// Transport.planMIDINotes drops them at playback. Lengthening restores them without
    /// re-authoring. Pruning notes inside resizeClip would silently destroy the user's
    /// music and is exactly the wrong fix. This suite pins that contract so nobody
    /// "fixes" resize later by deleting the hidden tail.
    tk.suite("Non-destructive clip trim: shorten hides tail, re-lengthen restores playback") {
        var project = Project.newUntitled()
        let head = Note(startBeat: 0.0, lengthBeats: 1.0, pitch: 60, velocity: 100)
        let mid = Note(startBeat: 2.0, lengthBeats: 1.0, pitch: 64, velocity: 90)
        let tail = Note(startBeat: 6.0, lengthBeats: 1.0, pitch: 67, velocity: 80)
        let originalNotes = [head, mid, tail]
        let clip = Clip(kind: .midi, name: "TrimMe", startBeat: 0, lengthBeats: 8.0,
                        midiNotes: originalNotes)
        project.tracks[0].clips = [clip]
        let clipID = clip.id
        let originalNoteIDs = originalNotes.map(\.id)

        // Shorten so only head and mid fall inside the window; tail is past the end.
        try project.resizeClip(id: clipID, toLengthBeats: 4)
        let shortClip = project.tracks[0].clips[0]
        tk.expectEqual(shortClip.lengthBeats, 4, "shortened length is 4")
        let notesWhileShort = shortClip.midiNotes ?? []
        tk.expectEqual(notesWhileShort.count, originalNotes.count,
                       "shorten keeps every original note in midiNotes")
        tk.expectEqual(notesWhileShort.map(\.id), originalNoteIDs,
                       "shorten preserves note ids and order")
        for (i, expected) in originalNotes.enumerated() {
            let got = notesWhileShort[i]
            tk.expectEqual(got.pitch, expected.pitch, "note \(i) pitch intact while short")
            tk.expectEqual(got.startBeat, expected.startBeat, "note \(i) start intact while short")
            tk.expectEqual(got.lengthBeats, expected.lengthBeats,
                           "note \(i) length intact while short")
            tk.expectEqual(got.velocity, expected.velocity,
                           "note \(i) velocity intact while short")
        }

        // Transport drops the tail while the clip is short; head and mid still plan.
        let spb = 0.5 // 120 BPM
        let planShort = Transport.planMIDINotes(
            notes: notesWhileShort,
            clipStartBeat: shortClip.startBeat,
            clipLengthBeats: shortClip.lengthBeats,
            playFromBeat: 0,
            secondsPerBeat: spb
        )
        tk.expect(!planShort.contains(where: { $0.pitch == tail.pitch }),
                  "plan while short has no event for tail pitch \(tail.pitch)")
        tk.expect(planShort.contains(where: { $0.pitch == head.pitch }),
                  "plan while short still has head note")
        tk.expect(planShort.contains(where: { $0.pitch == mid.pitch }),
                  "plan while short still has mid note")

        // Re-lengthen: stored notes still present; tail becomes playable again.
        try project.resizeClip(id: clipID, toLengthBeats: 8)
        let longClip = project.tracks[0].clips[0]
        tk.expectEqual(longClip.lengthBeats, 8, "re-lengthened length is 8")
        let notesRestored = longClip.midiNotes ?? []
        tk.expectEqual(notesRestored.count, originalNotes.count,
                       "re-lengthen still has every original note")
        tk.expect(notesRestored.contains(where: { $0.id == tail.id }),
                  "tail note still present after re-lengthen")

        let planLong = Transport.planMIDINotes(
            notes: notesRestored,
            clipStartBeat: longClip.startBeat,
            clipLengthBeats: longClip.lengthBeats,
            playFromBeat: 0,
            secondsPerBeat: spb
        )
        let plannedTail = planLong.first {
            $0.pitch == tail.pitch && $0.velocity == tail.velocity
        }
        tk.expect(plannedTail != nil, "plan after re-lengthen includes the tail note")
        if let plannedTail {
            let expectedOn = (longClip.startBeat + tail.startBeat) * spb
            tk.expectEqual(plannedTail.onSeconds, expectedOn,
                           "tail onset matches restored playback window")
        }
    }

    // MARK: - AC7 splitClip

    tk.suite("AC7: splitClip partitions notes; rejects edges; fresh clip ids") {
        var project = Project.newUntitled()
        // Clip 4…12. Split at arrangement 8 (local 4).
        // before 0…2, crossing 3…6, after 5…6.5
        let before = Note(startBeat: 0, lengthBeats: 2, pitch: 60, velocity: 100)
        let crossing = Note(startBeat: 3, lengthBeats: 3, pitch: 64, velocity: 90)
        let after = Note(startBeat: 5, lengthBeats: 1.5, pitch: 67, velocity: 80)
        let origTotal = before.lengthBeats + crossing.lengthBeats + after.lengthBeats
        let clip = Clip(kind: .midi, name: "SplitMe", startBeat: 4, lengthBeats: 8,
                        midiNotes: [before, crossing, after])
        project.tracks[0].clips = [clip]
        let origID = clip.id
        let origLen = clip.lengthBeats
        let origNoteIDs = Set([before.id, crossing.id, after.id])

        let pair = try project.splitClip(id: clip.id, atArrangementBeat: 8)
        tk.expectEqual(project.tracks[0].clips.count, 2, "two clips after split")
        let left = project.tracks[0].clips[0]
        let right = project.tracks[0].clips[1]
        tk.expectEqual(left.lengthBeats + right.lengthBeats, origLen,
                       "half lengths sum to original")
        tk.expectEqual(left.startBeat + left.lengthBeats, right.startBeat,
                       "halves abut with no gap")
        tk.expect(left.id != origID, "left half has a fresh clip id")
        tk.expect(right.id != origID, "right half has a fresh clip id")
        tk.expect(left.id != right.id, "halves have distinct clip ids")
        tk.expectEqual(left.id, pair.left.id, "return left matches placement")
        tk.expectEqual(right.id, pair.right.id, "return right matches placement")

        let leftNotes = left.midiNotes ?? []
        let rightNotes = right.midiNotes ?? []
        // Crossing becomes two notes → 4 total; every original pitch/duration accounted for.
        tk.expectEqual(leftNotes.count + rightNotes.count, 4,
                       "combined note count accounts for split crossing")
        let newTotal = (leftNotes + rightNotes).map(\.lengthBeats).reduce(0, +)
        tk.expectEqual(newTotal, origTotal, "combined note duration equals original (no loss)")
        let newIDs = Set((leftNotes + rightNotes).map(\.id))
        tk.expectEqual(newIDs.count, 4, "no duplicated note ids after split")
        tk.expect(origNoteIDs.isDisjoint(with: newIDs), "split notes are not the original note ids")
        // Pitch multiset: 60, 64, 64, 67 (crossing appears on both sides).
        let pitches = (leftNotes + rightNotes).map(\.pitch).sorted()
        tk.expectEqual(pitches, [60, 64, 64, 67], "every original note pitch accounted for")
        let crossLeft = leftNotes.first { $0.pitch == 64 }
        let crossRight = rightNotes.first { $0.pitch == 64 }
        tk.expect(crossLeft != nil && crossRight != nil, "crossing note present on both halves")
        if let cl = crossLeft, let cr = crossRight {
            tk.expectEqual(cl.lengthBeats + cr.lengthBeats, crossing.lengthBeats,
                           "crossing halves sum to original note length (no loss/dupe duration)")
        }

        // Reject split exactly at start or end; project unchanged for those attempts.
        var edgeProject = Project.newUntitled()
        let edgeClip = Clip(kind: .midi, name: "Edge", startBeat: 2, lengthBeats: 4,
                            midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        edgeProject.tracks[0].clips = [edgeClip]
        let edgeFP = projectFingerprint(edgeProject)
        tk.expectThrows("split at exact start rejected") {
            try edgeProject.splitClip(id: edgeClip.id, atArrangementBeat: 2)
        }
        tk.expectThrows("split at exact end rejected") {
            try edgeProject.splitClip(id: edgeClip.id, atArrangementBeat: 6)
        }
        tk.expectEqual(projectFingerprint(edgeProject), edgeFP,
                       "edge split rejects leave project unchanged")
        tk.expectEqual(edgeProject.tracks[0].clips.count, 1, "still one clip after edge rejects")
        tk.expectEqual(edgeProject.tracks[0].clips[0].id, edgeClip.id, "original clip id intact")

        // AppStore: arrangementSplitClip returns fresh ids and same length sum.
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asClip = Clip(kind: .midi, name: "ASSplit", startBeat: 0, lengthBeats: 8,
                          midiNotes: [
                            Note(startBeat: 1, lengthBeats: 1, pitch: 60, velocity: 100),
                            Note(startBeat: 5, lengthBeats: 1, pitch: 62, velocity: 100),
                          ])
        store.project.tracks[0].clips = [asClip]
        let result = store.arrangementSplitClip(id: asClip.id, atArrangementBeat: 4)
        tk.expect(result != nil, "AppStore split succeeds inside clip")
        if let r = result {
            tk.expect(r.left != asClip.id && r.right != asClip.id,
                      "AppStore both halves get fresh clip ids")
            tk.expect(r.left != r.right, "AppStore half ids distinct")
            tk.expectEqual(store.project.tracks[0].clips.count, 2, "AppStore two clips after split")
            let l = store.project.tracks[0].clips[0]
            let rr = store.project.tracks[0].clips[1]
            tk.expectEqual(l.lengthBeats + rr.lengthBeats, 8, "AppStore lengths sum to original")
            tk.expectEqual(l.id, r.left, "AppStore left id matches return")
            tk.expectEqual(rr.id, r.right, "AppStore right id matches return")
        }
        // Edge rejects via AppStore: nil return, project unchanged.
        let (store2, dir2) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let edge2 = Clip(kind: .midi, name: "E2", startBeat: 0, lengthBeats: 4,
                         midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        store2.project.tracks[0].clips = [edge2]
        let fp2 = projectFingerprint(store2.project)
        tk.expect(store2.arrangementSplitClip(id: edge2.id, atArrangementBeat: 0) == nil,
                  "AppStore rejects split at start")
        tk.expect(store2.arrangementSplitClip(id: edge2.id, atArrangementBeat: 4) == nil,
                  "AppStore rejects split at end")
        tk.expectEqual(projectFingerprint(store2.project), fp2,
                       "AppStore edge rejects leave project unchanged")
    }

    // MARK: - AC8 duplicateClip

    tk.suite("AC8: duplicateClip fresh ids for clip and notes; identical musical content") {
        var project = Project.newUntitled()
        let n1 = Note(startBeat: 0.0, lengthBeats: 1.0, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 1.5, lengthBeats: 0.5, pitch: 64, velocity: 88)
        let n3 = Note(startBeat: 3.0, lengthBeats: 0.25, pitch: 72, velocity: 120)
        let clip = Clip(kind: .midi, name: "DupMe", startBeat: 2, lengthBeats: 4,
                        midiNotes: [n1, n2, n3])
        project.tracks[0].clips = [clip]
        let origNoteIDs = Set([n1.id, n2.id, n3.id])

        let copy = try project.duplicateClip(id: clip.id)
        tk.expectEqual(project.tracks[0].clips.count, 2, "two clips after duplicate")
        tk.expect(copy.id != clip.id, "duplicate has a fresh clip id")
        tk.expectEqual(copy.startBeat, clip.startBeat + clip.lengthBeats,
                       "duplicate placed at start + length")
        tk.expectEqual(copy.lengthBeats, clip.lengthBeats, "duplicate length matches")
        tk.expectEqual(copy.name, clip.name, "duplicate name matches")
        tk.expectEqual(copy.kind, clip.kind, "duplicate kind matches")
        let copyNotes = copy.midiNotes ?? []
        let origNotes = project.tracks[0].clips[0].midiNotes ?? []
        tk.expectEqual(copyNotes.count, origNotes.count, "duplicate note count matches")
        let copyNoteIDs = Set(copyNotes.map(\.id))
        tk.expect(origNoteIDs.isDisjoint(with: copyNoteIDs),
                  "no note id shared with original")
        tk.expectEqual(copyNoteIDs.count, copyNotes.count, "duplicate note ids unique within clip")
        for i in origNotes.indices {
            tk.expectEqual(copyNotes[i].pitch, origNotes[i].pitch, "dup note \(i) pitch")
            tk.expectEqual(copyNotes[i].startBeat, origNotes[i].startBeat, "dup note \(i) start")
            tk.expectEqual(copyNotes[i].lengthBeats, origNotes[i].lengthBeats, "dup note \(i) length")
            tk.expectEqual(copyNotes[i].velocity, origNotes[i].velocity, "dup note \(i) velocity")
            tk.expect(copyNotes[i].id != origNotes[i].id, "dup note \(i) has fresh id")
        }
        // Original ids untouched.
        tk.expectEqual(project.tracks[0].clips[0].id, clip.id, "original clip id stable")
        tk.expectEqual(Set(origNotes.map(\.id)), origNoteIDs, "original note ids stable")

        // AppStore path.
        let (store, dir) = makeACStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a1 = Note(startBeat: 0.5, lengthBeats: 1, pitch: 55, velocity: 70)
        let a2 = Note(startBeat: 2, lengthBeats: 2, pitch: 57, velocity: 75)
        let aClip = Clip(kind: .midi, name: "ASDup", startBeat: 0, lengthBeats: 8,
                         midiNotes: [a1, a2])
        store.project.tracks[0].clips = [aClip]
        let newIDs = store.arrangementDuplicateClips(ids: [aClip.id])
        tk.expectEqual(newIDs.count, 1, "AppStore returns one new id")
        if let newID = newIDs.first {
            tk.expect(newID != aClip.id, "AppStore duplicate has fresh clip id")
            let orig = store.project.tracks[0].clips.first { $0.id == aClip.id }!
            let dup = store.project.tracks[0].clips.first { $0.id == newID }!
            let oNotes = orig.midiNotes ?? []
            let dNotes = dup.midiNotes ?? []
            tk.expectEqual(dNotes.count, oNotes.count, "AppStore note count matches")
            let oIDs = Set(oNotes.map(\.id))
            let dIDs = Set(dNotes.map(\.id))
            tk.expect(oIDs.isDisjoint(with: dIDs), "AppStore no shared note ids")
            for i in oNotes.indices {
                tk.expectEqual(dNotes[i].pitch, oNotes[i].pitch, "AppStore note \(i) pitch")
                tk.expectEqual(dNotes[i].startBeat, oNotes[i].startBeat, "AppStore note \(i) start")
                tk.expectEqual(dNotes[i].lengthBeats, oNotes[i].lengthBeats,
                               "AppStore note \(i) length")
                tk.expectEqual(dNotes[i].velocity, oNotes[i].velocity, "AppStore note \(i) velocity")
            }
        }
    }

    // MARK: - AC4 / AC12 / AC19 adversarial (silent data loss / wrong playback)

    runACAdversarialProbes(tk)

    // MARK: - AC5–AC8 seeded fuzz: random clip ops + invariants

    runACClipOpsFuzz(tk)
}

// MARK: - AC5–AC8 seeded fuzz helpers

/// At least 200 trials: random project, random sequence of move/resize/split/duplicate,
/// assert structural invariants after every step. Seeded for reproducibility.
private func runACClipOpsFuzz(_ tk: TestKit) {
    let seed: UInt64 = 0xAC58_F022
    let trials = 200
    let stepsPerTrial = 12

    tk.suite("AC5–AC8 clip-ops fuzz (seed 0xAC58F022, \(trials) trials)") {
        var rng = SeededRNG(seed: seed)
        var failures = 0
        var first: String?

        for trial in 0..<trials {
            var project = acFuzzRandomProject(rng: &rng)
            // Seeded projects must already satisfy invariants.
            if let msg = acClipOpsInvariantFailure(project) {
                failures += 1
                first = first ?? "trial \(trial) seed project: \(msg)"
                continue
            }
            if let msg = acJSONRoundTripFailure(project) {
                failures += 1
                first = first ?? "trial \(trial) seed round-trip: \(msg)"
                continue
            }

            for step in 0..<stepsPerTrial {
                acFuzzApplyRandomOp(to: &project, rng: &rng)
                if let msg = acClipOpsInvariantFailure(project) {
                    failures += 1
                    first = first ?? "trial \(trial) step \(step): \(msg)"
                    break
                }
                if let msg = acJSONRoundTripFailure(project) {
                    failures += 1
                    first = first ?? "trial \(trial) step \(step) round-trip: \(msg)"
                    break
                }
            }
        }

        tk.expect(failures == 0, "clip-ops fuzz invariants hold",
                  first ?? "all \(trials) trials ok")
        tk.expectEqual(failures, 0, "clip-ops fuzz failure count is zero")
    }

}

// MARK: - AC4 / AC12 / AC19 adversarial probes

@MainActor
private func runACAdversarialProbes(_ tk: TestKit) {
    // MARK: - AC4 loop playback (plan clips to clip; loop wrap is stop+reschedule)

    tk.suite("AC4: plan clips to clip; loop wrap is stop+reschedule, not plan clip") {
        let spb = 0.5 // 120 BPM
        // Long arrangement with notes inside the loop, straddling the end, and past it.
        let inside = Note(startBeat: 4.5, lengthBeats: 0.5, pitch: 60, velocity: 100)
        let straddle = Note(startBeat: 7.0, lengthBeats: 3.0, pitch: 64, velocity: 90)
        let past = Note(startBeat: 10.0, lengthBeats: 1.0, pitch: 67, velocity: 80)
        let early = Note(startBeat: 0.0, lengthBeats: 1.0, pitch: 48, velocity: 70)
        // Clip-edge notes for the clipLengthBeats contract on this same loop setup.
        let clipStraddle = Note(startBeat: 15.0, lengthBeats: 3.0, pitch: 77, velocity: 100)
        let afterClip = Note(startBeat: 16.0, lengthBeats: 1.0, pitch: 78, velocity: 100)
        let clip = Clip(kind: .midi, name: "AC4", startBeat: 0, lengthBeats: 16,
                        midiNotes: [early, inside, straddle, past, clipStraddle, afterClip])
        var project = Project.newUntitled()
        project.tracks[0].clips = [clip]
        project.tempoBPM = 120

        let region = 4.0...8.0
        let loop = LoopRegionLogic.playbackLoop(loopOn: true, region: region, arrangementEnd: 16)
        tk.expectEqual(loop, 4.0...8.0, "playbackLoop with region uses the region")

        // playbackStart: before / inside / at end / after.
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 0, loop: loop), 4,
                       "playhead before loop → loop start")
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 6, loop: loop), 6,
                       "playhead inside loop kept")
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 8, loop: loop), 4,
                       "playhead at half-open end → loop start")
        tk.expectEqual(LoopRegionLogic.playbackStart(playhead: 12, loop: loop), 4,
                       "playhead after loop → loop start")

        // planMIDINotes clips to clipLengthBeats only (loop is not a plan bound).
        let fromBefore = LoopRegionLogic.playbackStart(playhead: 0, loop: region)
        let planBefore = acPlanArrangementMIDI(
            project: project, playFromBeat: fromBefore, secondsPerBeat: spb)
        tk.expect(!planBefore.contains(where: { $0.pitch == afterClip.pitch }),
                  "note at/after clip end (pitch \(afterClip.pitch)) not scheduled")
        if let cs = planBefore.first(where: { $0.pitch == clipStraddle.pitch }) {
            let offBeat = fromBefore + cs.offSeconds / spb
            tk.expectEqual(offBeat, 16.0,
                           "note straddling clip end truncates at clipLengthBeats")
        } else {
            tk.expect(false, "clip-straddle note with onset before clip end must be planned")
        }

        // A plan MAY contain events past the loop end. That is correct: Transport.play begins
        // with stop() (cancel every pending MIDI work item and allNotesOff), and the loopTimer
        // calls play(from: loop.lowerBound) at the wrap. Post-loop plan events are cancelled
        // before they can sound; a straddling note is cut by allNotesOff at the wrap.
        tk.expect(planBefore.contains(where: { $0.pitch == past.pitch }),
                  "plan may include note past loop end (loop enforced by stop+reschedule)")
        if let s = planBefore.first(where: { $0.pitch == straddle.pitch }) {
            let offBeat = fromBefore + s.offSeconds / spb
            tk.expect(offBeat > region.upperBound + 1e-9,
                      "straddle note-off past loop end is expected in the plan (got \(offBeat))")
        } else {
            tk.expect(false, "straddle note with onset after playhead must be scheduled")
        }

        // Playhead filter (not loop filter): notes wholly before playFrom are dropped.
        tk.expect(!planBefore.contains(where: { $0.pitch == early.pitch }),
                  "note wholly before playhead (pitch \(early.pitch)) not scheduled")
        tk.expect(planBefore.contains(where: { $0.pitch == inside.pitch }),
                  "inside note still scheduled from loop start")

        // playbackStart positions: plan is finite and well-formed (not loop-bounded).
        for (label, ph) in [("before", 0.0), ("inside", 6.0), ("after", 12.0)] {
            let from = LoopRegionLogic.playbackStart(playhead: ph, loop: region)
            let planned = acPlanArrangementMIDI(
                project: project, playFromBeat: from, secondsPerBeat: spb)
            tk.expect(planned.count < 10_000,
                      "playhead-\(label) plan finite (got \(planned.count))")
            let issues = acPlanWellFormedIssues(planned)
            tk.expect(issues.isEmpty, "playhead-\(label) plan well-formed",
                      issues.first ?? "ok")
        }

        // Loop shorter than one beat: finite; not required to be confined to the region.
        let shortRegion = LoopRegionLogic.normalized(start: 2.0, end: 2.25)
        tk.expect(shortRegion != nil, "sub-beat loop (>= minimum) accepted")
        if let short = shortRegion {
            let from = LoopRegionLogic.playbackStart(playhead: 0, loop: short)
            let planned = acPlanArrangementMIDI(
                project: project, playFromBeat: from, secondsPerBeat: spb)
            tk.expect(planned.count < 10_000, "short loop plan is finite (got \(planned.count))")
            let shortIssues = acPlanWellFormedIssues(planned)
            tk.expect(shortIssues.isEmpty, "short loop plan well-formed",
                      shortIssues.first ?? "ok")
        }

        // Loop bounds sit mid-note: plan stays finite. Off may extend past loop end
        // (wrap cancels it); clip length still bounds the plan.
        let midNote = Note(startBeat: 3.5, lengthBeats: 4.0, pitch: 72, velocity: 100)
        var midProject = Project.newUntitled()
        midProject.tracks[0].clips = [
            Clip(kind: .midi, name: "mid", startBeat: 0, lengthBeats: 16, midiNotes: [midNote])
        ]
        let midLoop = 3.0...5.0
        let midFrom = LoopRegionLogic.playbackStart(playhead: 4, loop: midLoop)
        tk.expectEqual(midFrom, 4, "playhead inside mid-note loop kept")
        let midPlan = acPlanArrangementMIDI(
            project: midProject, playFromBeat: midFrom, secondsPerBeat: spb)
        tk.expect(midPlan.count < 10_000, "mid-note loop plan finite")
        tk.expect(acPlanWellFormedIssues(midPlan).isEmpty, "mid-note loop plan well-formed")
        if let m = midPlan.first(where: { $0.pitch == midNote.pitch }) {
            let offBeat = midFrom + m.offSeconds / spb
            tk.expect(offBeat > midLoop.upperBound + 1e-9,
                      "mid-note plan off may pass loop end (got \(offBeat))")
        }

        // Zero-length loop: no hang / infinite events. Normalized rejects for UI path.
        let zeroLoop: ClosedRange<Double> = 4.0...4.0
        let zeroFrom = LoopRegionLogic.playbackStart(playhead: 0, loop: zeroLoop)
        tk.expectEqual(zeroFrom, 4, "zero-length loop still yields a start beat")
        let zeroPlan = acPlanArrangementMIDI(
            project: project, playFromBeat: zeroFrom, secondsPerBeat: spb)
        tk.expect(zeroPlan.count < 10_000, "zero-length loop plan is finite")
        tk.expect(LoopRegionLogic.normalized(start: 4, end: 4) == nil,
                  "normalized rejects zero-length")
        if let inv = LoopRegionLogic.normalized(start: 9, end: 1) {
            tk.expect(inv.lowerBound <= inv.upperBound, "normalized inverted keeps lower <= upper")
            tk.expect(inv.upperBound - inv.lowerBound >= LoopRegionLogic.minimumLengthBeats - 1e-12,
                      "normalized inverted meets minimum length")
        }
        tk.expect(LoopRegionLogic.normalized(start: 1.01, end: 1.0) == nil,
                  "tiny inverted span rejected")

        // loopLen floor: Transport uses max(0.1, regionBeats * spb). Pure formula, no wall clock.
        let tinyRegion: ClosedRange<Double> = 0...0.1  // 0.05s at 120 BPM, under the floor
        let loopLenSeconds = max(0.1, (tinyRegion.upperBound - tinyRegion.lowerBound) * spb)
        tk.expectEqual(loopLenSeconds, 0.1, "loopLen floors at 0.1s (Transport loop timer)")
        let longRegion: ClosedRange<Double> = 0...4    // 2.0s at 120 BPM
        let longLoopLen = max(0.1, (longRegion.upperBound - longRegion.lowerBound) * spb)
        tk.expectEqual(longLoopLen, 2.0, "loopLen uses region length when above floor")

        // Seeded cloud: finite + well-formed plans; clip clipping holds; loop not a plan bound.
        var rng = SeededRNG(seed: 0xAC04_1001)
        var cloudFails = 0
        var cloudFirst: String?
        for trial in 0..<40 {
            let lo = rng.nextDouble(in: 0...12)
            let hi = lo + rng.nextDouble(in: LoopRegionLogic.minimumLengthBeats...6)
            guard let reg = LoopRegionLogic.normalized(start: lo, end: hi) else { continue }
            let nCount = rng.nextInt(in: 1...8)
            var notes: [Note] = []
            for _ in 0..<nCount {
                notes.append(Note(
                    startBeat: rng.nextDouble(in: 0...15),
                    lengthBeats: rng.nextDouble(in: 0.05...4),
                    pitch: rng.nextInt(in: 0...127),
                    velocity: rng.nextInt(in: 1...127)
                ))
            }
            let clipLen = 16.0
            var p = Project.newUntitled()
            p.tracks[0].clips = [Clip(kind: .midi, name: "fz", startBeat: 0, lengthBeats: clipLen,
                                      midiNotes: notes)]
            let pb = rng.nextDouble(in: -1...20)
            let from = LoopRegionLogic.playbackStart(playhead: pb, loop: reg)
            let planned = acPlanArrangementMIDI(project: p, playFromBeat: from, secondsPerBeat: spb)
            if planned.count > 10_000 {
                cloudFails += 1
                cloudFirst = cloudFirst ?? "trial \(trial): plan count \(planned.count)"
                continue
            }
            if let first = acPlanWellFormedIssues(planned).first {
                cloudFails += 1
                cloudFirst = cloudFirst ?? "trial \(trial): \(first)"
                continue
            }
            // Clip contract: no note-off past clip end (relative to playFrom).
            for (i, ev) in planned.enumerated() {
                let offBeat = from + ev.offSeconds / spb
                if offBeat > clipLen + 1e-9 {
                    cloudFails += 1
                    cloudFirst = cloudFirst ?? "trial \(trial): ev\(i) off \(offBeat) past clip \(clipLen)"
                    break
                }
            }
        }
        tk.expect(cloudFails == 0, "AC4 seeded loop plan cloud clean",
                  cloudFirst ?? "40 trials ok")
    }

    // MARK: - AC12 crash recovery (adversarial: silent data loss)

    tk.suite("AC12: crash recovery restores content; corrupt/future refuse; discard/prune safe") {
        let fm = FileManager.default

        // --- Happy path: autosave, no clean shutdown, recover same content ---
        let baseOK = fm.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC12-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: baseOK) }
        let recOK = RecoveryManager(baseDir: baseOK)
        recOK.beginSession()
        var edited = Project.newUntitled()
        edited.title = "AC12 Unsaved"
        edited.tempoBPM = 137
        let n1 = Note(startBeat: 0.25, lengthBeats: 1.5, pitch: 61, velocity: 111)
        let n2 = Note(startBeat: 2.0, lengthBeats: 0.5, pitch: 65, velocity: 99)
        let c1 = Clip(kind: .midi, name: "Hook", startBeat: 4, lengthBeats: 8,
                      midiNotes: [n1, n2])
        edited.tracks[0].name = "Lead"
        edited.tracks[0].colorIndex = 3
        edited.tracks[0].clips = [c1]
        edited.tracks.append(Track(
            kind: .audio, name: "Vox", colorIndex: 1,
            clips: [Clip(kind: .audio, name: "Take", startBeat: 0, lengthBeats: 8,
                         mediaFile: "take-ac12.caf", mediaStartSeconds: 0.5)]))
        let expectedFP = projectFingerprint(edited)
        let expectedTitle = edited.title
        let expectedTempo = edited.tempoBPM
        let expectedTrackNames = edited.tracks.map(\.name)
        let expectedNoteIDs = [n1.id, n2.id]
        recOK.autosave(edited)
        // Simulate crash: do NOT call endSessionCleanly / discardRecovery.
        let relaunchOK = RecoveryManager(baseDir: baseOK)
        let infoOK = relaunchOK.detectRecovery()
        tk.expect(infoOK != nil, "detectRecovery reports recoverable work after unclean exit")
        tk.expect(infoOK?.project != nil, "recovered project present")
        tk.expectEqual(infoOK?.projectLoadFailureMessage, nil,
                       "valid autosave has no projectLoadFailureMessage")
        if let recovered = infoOK?.project {
            tk.expectEqual(projectFingerprint(recovered), expectedFP,
                           "recovered project fingerprint matches autosaved content")
            tk.expectEqual(recovered.title, expectedTitle, "recovered title")
            tk.expectEqual(recovered.tempoBPM, expectedTempo, "recovered tempo")
            tk.expectEqual(recovered.tracks.map(\.name), expectedTrackNames, "recovered track names")
            tk.expectEqual(recovered.tracks[0].colorIndex, 3, "recovered colour")
            let notes = recovered.tracks[0].clips.first?.midiNotes ?? []
            tk.expectEqual(notes.map(\.id), expectedNoteIDs, "recovered note ids")
            tk.expectEqual(notes.first?.pitch, 61, "recovered note pitch")
            tk.expectEqual(recovered.tracks[1].clips.first?.mediaFile, "take-ac12.caf",
                           "recovered audio mediaFile")
            tk.expectEqual(recovered.tracks[1].clips.first?.mediaStartSeconds, 0.5,
                           "recovered mediaStartSeconds")
        }

        // --- Truncated autosave: load failure, never silent "no work" ---
        let baseTrunc = fm.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC12-trunc-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: baseTrunc) }
        let recTrunc = RecoveryManager(baseDir: baseTrunc)
        recTrunc.beginSession()
        var truncProject = Project.newUntitled()
        truncProject.title = "Will Truncate"
        truncProject.tempoBPM = 100
        truncProject.tracks[0].clips = [
            Clip(kind: .midi, name: "T", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        ]
        recTrunc.autosave(truncProject)
        let autosaveURL = recTrunc.workspaceDir.appendingPathComponent("autosave-project.json")
        tk.expect(fm.fileExists(atPath: autosaveURL.path), "autosave written before chop")
        let fullData = try Data(contentsOf: autosaveURL)
        tk.expect(fullData.count > 40, "autosave large enough to chop (got \(fullData.count))")
        for chop in [1, 17, fullData.count / 2, fullData.count - 5, fullData.count] {
            let keep = max(0, fullData.count - chop)
            let chopped = fullData.prefix(keep)
            try Data(chopped).write(to: autosaveURL, options: [.atomic])
            let info = RecoveryManager(baseDir: baseTrunc).detectRecovery()
            tk.expect(info != nil,
                      "truncated autosave (chop \(chop)) still surfaces recovery, not silent nil")
            tk.expect(info?.project == nil,
                      "truncated autosave (chop \(chop)) does not yield a partial project")
            let fail = info?.projectLoadFailureMessage ?? ""
            tk.expect(!fail.isEmpty,
                      "truncated autosave (chop \(chop)) sets projectLoadFailureMessage")
            // File retained for the user (not deleted as garbage).
            tk.expect(fm.fileExists(atPath: autosaveURL.path),
                      "truncated autosave retained on disk after detect (chop \(chop))")
        }

        // --- Future schemaVersion: refuse, never silent drop of unknown fields ---
        let baseFuture = fm.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC12-future-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: baseFuture) }
        let recFuture = RecoveryManager(baseDir: baseFuture)
        recFuture.beginSession()
        let futureV = Schema.current + 50
        let futureJSON = """
        {
          "schemaVersion": \(futureV),
          "id": "00000000-0000-4000-8000-0000000000AC",
          "title": "Future AC12",
          "tempoBPM": 88,
          "timeSignature": { "num": 4, "den": 4 },
          "tracks": [],
          "masterVolume": 0.8,
          "createdAt": "1970-01-01T00:00:00Z",
          "modifiedAt": "1970-01-01T00:00:00Z",
          "futureOnlyField": { "mustNotSilentlyDrop": true }
        }
        """
        let futureData = Data(futureJSON.utf8)
        let futureAutosave = recFuture.workspaceDir.appendingPathComponent("autosave-project.json")
        try futureData.write(to: futureAutosave, options: [.atomic])
        let infoFuture = RecoveryManager(baseDir: baseFuture).detectRecovery()
        tk.expect(infoFuture != nil, "future-schema autosave surfaces recovery")
        tk.expect(infoFuture?.project == nil,
                  "future schema is not partially decoded as a project")
        let futureFail = infoFuture?.projectLoadFailureMessage ?? ""
        tk.expect(!futureFail.isEmpty, "future schema sets projectLoadFailureMessage")
        tk.expect(futureFail.localizedCaseInsensitiveContains("newer")
                  || futureFail.localizedCaseInsensitiveContains("schema")
                  || futureFail.localizedCaseInsensitiveContains("version"),
                  "future schema failure mentions schema/version/newer")
        // Direct open path also refuses (no silent field drop on re-save).
        var openedFuture = false
        do {
            _ = try Project.fromJSON(futureData)
            openedFuture = true
        } catch { /* expected */ }
        tk.expect(!openedFuture, "Project.fromJSON refuses future schemaVersion")
        tk.expect(fm.fileExists(atPath: futureAutosave.path),
                  "future autosave retained after detectRecovery")

        // --- discardRecovery: on-disk .verse package intact; recovery state only removed ---
        let baseDiscard = fm.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC12-discard-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: baseDiscard) }
        let pkgRoot = baseDiscard.appendingPathComponent("packages", isDirectory: true)
        try fm.createDirectory(at: pkgRoot, withIntermediateDirectories: true)
        var diskProject = Project.newUntitled()
        diskProject.title = "Saved On Disk"
        diskProject.tempoBPM = 120
        diskProject.tracks[0].clips = [
            Clip(kind: .midi, name: "Keep", startBeat: 0, lengthBeats: 4,
                 midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 72, velocity: 100)])
        ]
        let pkg = pkgRoot.appendingPathComponent("Saved.verse")
        try ProjectPackage.write(diskProject, to: pkg, mediaSourceDir: nil)
        let diskFP = projectFingerprint(try ProjectPackage.read(pkg))

        let recDiscard = RecoveryManager(baseDir: baseDiscard)
        recDiscard.beginSession()
        var dirty = Project.newUntitled()
        dirty.title = "Dirty Recovery Only"
        dirty.tempoBPM = 50
        recDiscard.autosave(dirty)
        let orphan = recDiscard.newTakeURL()
        try Data([0x01, 0x02, 0x03]).write(to: orphan)
        recDiscard.noteRecordingStarted(takeFilename: orphan.lastPathComponent)
        // Unrelated media that belongs to other work must survive discard.
        let keepMedia = recDiscard.mediaDir.appendingPathComponent("other-project.caf")
        try Data([0xAA]).write(to: keepMedia)

        recDiscard.discardRecovery()
        tk.expect(RecoveryManager(baseDir: baseDiscard).detectRecovery() == nil,
                  "discardRecovery clears recovery offer")
        tk.expect(!fm.fileExists(
            atPath: recDiscard.workspaceDir.appendingPathComponent("autosave-project.json").path),
                  "discard removes autosave")
        tk.expect(!fm.fileExists(
            atPath: recDiscard.workspaceDir.appendingPathComponent("session.lock").path),
                  "discard removes session lock")
        tk.expect(!fm.fileExists(atPath: orphan.path),
                  "discard removes journaled in-progress take only")
        tk.expect(fm.fileExists(atPath: keepMedia.path),
                  "discard leaves unrelated media intact")
        let afterDiscard = try ProjectPackage.read(pkg)
        tk.expectEqual(projectFingerprint(afterDiscard), diskFP,
                       "discardRecovery leaves on-disk .verse package content unchanged")
        tk.expectEqual(afterDiscard.title, "Saved On Disk", "package title intact after discard")
        tk.expectEqual(afterDiscard.tracks[0].clips.first?.midiNotes?.first?.pitch, 72,
                       "package notes intact after discard")

        // --- pruneMedia: never delete media still referenced by a clip ---
        let basePrune = fm.temporaryDirectory
            .appendingPathComponent("VerseCheck-AC12-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: basePrune) }
        let recPrune = RecoveryManager(baseDir: basePrune)
        let refA = "clip-ref-a.caf"
        let refB = "clip-ref-b.caf"
        let orphanName = "orphan-unreferenced.caf"
        try Data([1]).write(to: recPrune.mediaDir.appendingPathComponent(refA))
        try Data([2]).write(to: recPrune.mediaDir.appendingPathComponent(refB))
        try Data([3]).write(to: recPrune.mediaDir.appendingPathComponent(orphanName))
        // Project that still references both A and B (as real clips would).
        var mediaProject = Project.newUntitled()
        mediaProject.tracks = [
            Track(kind: .audio, name: "A", clips: [
                Clip(kind: .audio, name: "A", startBeat: 0, lengthBeats: 4, mediaFile: refA)
            ]),
            Track(kind: .audio, name: "B", clips: [
                Clip(kind: .audio, name: "B", startBeat: 4, lengthBeats: 4, mediaFile: refB)
            ])
        ]
        let referenced = Set(mediaProject.tracks.flatMap { $0.clips.compactMap(\.mediaFile) })
        tk.expectEqual(referenced, [refA, refB], "referenced set from clips")
        recPrune.pruneMedia(keeping: referenced)
        tk.expect(fm.fileExists(atPath: recPrune.mediaDir.appendingPathComponent(refA).path),
                  "pruneMedia keeps clip-referenced \(refA)")
        tk.expect(fm.fileExists(atPath: recPrune.mediaDir.appendingPathComponent(refB).path),
                  "pruneMedia keeps clip-referenced \(refB)")
        tk.expect(!fm.fileExists(atPath: recPrune.mediaDir.appendingPathComponent(orphanName).path),
                  "pruneMedia removes unreferenced orphan")
        // Second prune with the same set must not delete the keepers.
        recPrune.pruneMedia(keeping: referenced)
        tk.expect(fm.fileExists(atPath: recPrune.mediaDir.appendingPathComponent(refA).path),
                  "second prune still keeps \(refA)")
        tk.expect(fm.fileExists(atPath: recPrune.mediaDir.appendingPathComponent(refB).path),
                  "second prune still keeps \(refB)")
        // Empty keep set may clear files, but must not throw or remove the Media directory.
        recPrune.pruneMedia(keeping: [])
        tk.expect(fm.fileExists(atPath: recPrune.mediaDir.path),
                  "Media directory survives empty keep-set prune")
    }

    // MARK: - AC19 layout logic (valid domain: no NaN / negative / row disagreement)

    tk.suite("AC19: ActionBarLogic + PianoRollLayout valid-domain sizes never NaN/negative") {
        // ActionBarLogic: extreme zoom / empty selection / nonsense content beats.
        let zooms: [Double] = [
            0, -1, -1e9, 1e-20, 1e9, Double.nan,
            Double.infinity, -Double.infinity,
            BeatTimeline.minZoom, BeatTimeline.maxZoom,
            BeatTimeline.minZoom / 2, BeatTimeline.maxZoom * 2
        ]
        for z in zooms {
            let zin = ActionBarLogic.zoomInHelp(zoom: z)
            let zout = ActionBarLogic.zoomOutHelp(zoom: z)
            tk.expect(!zin.help.isEmpty, "zoomInHelp non-empty help at zoom \(z)")
            tk.expect(!zout.help.isEmpty, "zoomOutHelp non-empty help at zoom \(z)")
            // enabled is a Bool; just force evaluation (no trap on NaN compares).
            _ = zin.enabled
            _ = zout.enabled
        }
        for beats in [-100.0, -1.0, 0.0, 0.0001, 1.0, 1e12, Double.nan, Double.infinity] {
            let fit = ActionBarLogic.zoomFitHelp(contentBeats: beats)
            tk.expect(!fit.help.isEmpty, "zoomFitHelp non-empty at contentBeats \(beats)")
        }
        // Selection extremes for enablement helpers (must not trap; help non-empty).
        var emptyProject = Project.newUntitled()
        emptyProject.tracks[0].clips = []
        let hugeSelect = Set((0..<500).map { _ in UUID() })
        let splitEmpty = ActionBarLogic.splitHelp(
            selectedClipIDs: [], project: emptyProject, playheadBeat: 0)
        tk.expect(!splitEmpty.enabled && !splitEmpty.help.isEmpty, "split empty selection disabled")
        let splitHuge = ActionBarLogic.splitHelp(
            selectedClipIDs: hugeSelect, project: emptyProject, playheadBeat: -5)
        tk.expect(!splitHuge.enabled && !splitHuge.help.isEmpty, "split multi-select disabled")
        let dupHuge = ActionBarLogic.duplicateHelp(selectedClipIDs: hugeSelect)
        tk.expect(dupHuge.enabled && !dupHuge.help.isEmpty, "duplicate multi enabled with help")
        let delNotes = ActionBarLogic.deleteHelp(
            surface: .pianoRoll, selectedClipIDs: [], selectedNoteIDs: hugeSelect)
        tk.expect(delNotes.enabled && !delNotes.help.isEmpty, "delete many notes enabled")
        let delNone = ActionBarLogic.deleteHelp(
            surface: .arrangement, selectedClipIDs: [], selectedNoteIDs: [])
        tk.expect(!delNone.enabled && !delNone.help.isEmpty, "delete none disabled with help")
        let loopMany = ActionBarLogic.loopFromClipHelp(selectedClipIDs: hugeSelect)
        tk.expect(!loopMany.enabled && !loopMany.help.isEmpty, "loop multi-select disabled")
        let clear = ActionBarLogic.clearLoopHelp(hasRegion: false)
        tk.expect(!clear.enabled && !clear.help.isEmpty, "clear loop empty disabled")

        // fitBandHeights: only inputs call sites can produce (TimelineWorkspaceView).
        // Call site mins: arrangementMinHeight = laneHeight*2, rollMinHeight = 140 (positive).
        // Workspace carries minHeight so availableHeight is never a zero/negative garbage budget.
        let callSiteMinArr = ArrangementLayout.laneHeight * 2
        let callSiteMinRoll: CGFloat = 140
        let rulerH = BeatTimeline.rulerHeight
        let dividerH: CGFloat = 8
        let workspaceMinCollapsed: CGFloat = 180
        let workspaceMinExpanded = callSiteMinArr + callSiteMinRoll + rulerH + 8

        // Collapsed roll at the workspace minimum: finite, non-negative, roll == 0, stack fits.
        let collapsedWS = PianoRollLayout.fitBandHeights(
            availableHeight: workspaceMinCollapsed,
            rulerHeight: rulerH,
            dividerHeight: dividerH,
            rollExpanded: false,
            preferredArrangement: ArrangementLayout.defaultBandHeight,
            preferredRoll: PianoRollLayout.defaultBandHeight,
            minArrangement: callSiteMinArr,
            minRoll: callSiteMinRoll
        )
        tk.expect(collapsedWS.arrangement.isFinite && !collapsedWS.arrangement.isNaN
                    && collapsedWS.roll.isFinite && !collapsedWS.roll.isNaN,
                  "collapsed workspace-min fit is finite")
        tk.expect(collapsedWS.arrangement >= 0 && collapsedWS.roll >= 0,
                  "collapsed workspace-min non-negative (arr \(collapsedWS.arrangement), roll \(collapsedWS.roll))")
        tk.expectEqual(collapsedWS.roll, 0, "collapsed roll is 0")
        let collapsedBudget = max(0, workspaceMinCollapsed - rulerH)
        tk.expect(collapsedWS.arrangement + collapsedWS.roll <= collapsedBudget + 1e-6,
                  "collapsed stack fits budget \(collapsedBudget) (got arr \(collapsedWS.arrangement))")

        // Expanded at workspace minimum with positive call-site mins.
        let expandedWS = PianoRollLayout.fitBandHeights(
            availableHeight: workspaceMinExpanded,
            rulerHeight: rulerH,
            dividerHeight: dividerH,
            rollExpanded: true,
            preferredArrangement: ArrangementLayout.defaultBandHeight,
            preferredRoll: PianoRollLayout.defaultBandHeight,
            minArrangement: callSiteMinArr,
            minRoll: callSiteMinRoll
        )
        tk.expect(expandedWS.arrangement.isFinite && !expandedWS.arrangement.isNaN
                    && expandedWS.roll.isFinite && !expandedWS.roll.isNaN,
                  "expanded workspace-min fit is finite")
        tk.expect(expandedWS.arrangement >= 0 && expandedWS.roll >= 0,
                  "expanded workspace-min non-negative (arr \(expandedWS.arrangement), roll \(expandedWS.roll))")
        let expandedBudget = max(0, workspaceMinExpanded - rulerH - dividerH)
        tk.expect(expandedWS.arrangement + expandedWS.roll <= expandedBudget + 1e-6,
                  "expanded stack fits budget \(expandedBudget)")

        // Valid-domain available heights: workspace floor for each mode, up through large viewports.
        let validAvails: [CGFloat] = [
            workspaceMinCollapsed, workspaceMinExpanded,
            320, 480, 640, 900, 1_200, 2_000
        ]
        for expanded in [false, true] {
            let floor = expanded ? workspaceMinExpanded : workspaceMinCollapsed
            for avail in validAvails where avail + 1e-9 >= floor {
                let r = PianoRollLayout.fitBandHeights(
                    availableHeight: avail,
                    rulerHeight: rulerH,
                    dividerHeight: dividerH,
                    rollExpanded: expanded,
                    preferredArrangement: ArrangementLayout.defaultBandHeight,
                    preferredRoll: PianoRollLayout.defaultBandHeight,
                    minArrangement: callSiteMinArr,
                    minRoll: callSiteMinRoll
                )
                tk.expect(r.arrangement.isFinite && !r.arrangement.isNaN && r.arrangement >= 0
                            && r.roll.isFinite && !r.roll.isNaN && r.roll >= 0,
                          "fitBand safe at avail \(avail) exp=\(expanded) (arr \(r.arrangement), roll \(r.roll))")
                if !expanded {
                    tk.expectEqual(r.roll, 0, "collapsed roll is 0 at avail \(avail)")
                }
            }
        }

        // Combinatorial sweep over the VALID call-site domain only.
        // Call sites always pass positive mins (laneHeight*2, 140) and geo.height that is
        // at least the workspace minHeight for the current expanded state.
        var fitFails = 0
        var fitFirst: String?
        let validHeights: [CGFloat] = [
            workspaceMinCollapsed, workspaceMinExpanded, 300, 400, 640, 900, 1_600
        ]
        let prefsArr: [CGFloat] = [
            callSiteMinArr, ArrangementLayout.defaultBandHeight, ArrangementLayout.laneHeight * 6
        ]
        let prefsRoll: [CGFloat] = [
            callSiteMinRoll, PianoRollLayout.defaultBandHeight, 400
        ]
        for expanded in [false, true] {
            let floor = expanded ? workspaceMinExpanded : workspaceMinCollapsed
            for avail in validHeights where avail + 1e-9 >= floor {
                for prefA in prefsArr {
                    for prefR in prefsRoll {
                        let result = PianoRollLayout.fitBandHeights(
                            availableHeight: avail,
                            rulerHeight: rulerH,
                            dividerHeight: dividerH,
                            rollExpanded: expanded,
                            preferredArrangement: prefA,
                            preferredRoll: prefR,
                            minArrangement: callSiteMinArr,
                            minRoll: callSiteMinRoll
                        )
                        if !result.arrangement.isFinite || result.arrangement.isNaN
                            || !result.roll.isFinite || result.roll.isNaN {
                            fitFails += 1
                            fitFirst = fitFirst ?? "NaN/inf avail=\(avail) exp=\(expanded) \(result)"
                            continue
                        }
                        if result.arrangement < 0 || result.roll < 0 {
                            fitFails += 1
                            fitFirst = fitFirst ?? "negative size avail=\(avail) exp=\(expanded) \(result)"
                            continue
                        }
                        if !expanded && result.roll != 0 {
                            fitFails += 1
                            fitFirst = fitFirst ?? "collapsed roll != 0 (\(result.roll))"
                            continue
                        }
                        let chrome = expanded ? rulerH + dividerH : rulerH
                        let budget = max(0, avail - chrome)
                        let stack = result.arrangement + result.roll
                        if stack > budget + 1e-6 {
                            fitFails += 1
                            fitFirst = fitFirst ?? "stack \(stack) > budget \(budget) avail=\(avail) exp=\(expanded)"
                            continue
                        }
                        // Row count agrees with fitted roll height (expanded only).
                        if expanded && result.roll > 0 {
                            let pane = max(0, result.roll - PianoRollLayout.snapToolbarHeight)
                            let drawn = PianoRollLayout.drawnRowCount(
                                paneHeight: pane, rowHeight: PianoRollLayout.rowHeight)
                            let range = PianoRollLayout.visiblePitchRange(
                                focusPitch: 60, paneHeight: pane, rowHeight: PianoRollLayout.rowHeight)
                            let count = range.upperBound - range.lowerBound + 1
                            if drawn < 1 || count != min(drawn, 128) {
                                fitFails += 1
                                fitFirst = fitFirst ?? "row count \(count) != drawn \(drawn) avail=\(avail) roll=\(result.roll)"
                            }
                        }
                    }
                }
            }
        }
        tk.expect(fitFails == 0, "fitBandHeights valid-domain sweep clean",
                  fitFirst ?? "ok")

        // drawnRowCount + visiblePitchRange: first-failure sweep over degenerates.
        var pitchFails = 0
        var pitchFirst: String?
        let panes: [CGFloat] = [
            0, 1, -1, -50, 0.25, 0.5,
            PianoRollLayout.rowHeight,
            PianoRollLayout.rowHeight * 0.5,
            PianoRollLayout.rowHeight * 24,
            PianoRollLayout.rowHeight * 200,
            1e6, -1e6
        ]
        let rowHs: [CGFloat] = [
            0, 1, -1, -10, 0.01,
            PianoRollLayout.minRowHeight, PianoRollLayout.rowHeight,
            PianoRollLayout.maxRowHeight, 100, 1e6
        ]
        let focuses = [-100, -1, 0, 1, 60, 127, 200, Int.min / 4, Int.max / 4]
        for pane in panes {
            for rh in rowHs {
                let drawn = PianoRollLayout.drawnRowCount(paneHeight: pane, rowHeight: rh)
                if drawn < 1 {
                    pitchFails += 1
                    pitchFirst = pitchFirst ?? "drawnRowCount \(drawn) < 1 pane=\(pane) rh=\(rh)"
                    continue
                }
                for focus in focuses {
                    let range = PianoRollLayout.visiblePitchRange(
                        focusPitch: focus, paneHeight: pane, rowHeight: rh)
                    if range.lowerBound < 0 || range.upperBound > 127 || range.lowerBound > range.upperBound {
                        pitchFails += 1
                        pitchFirst = pitchFirst ?? "bad range \(range) focus=\(focus) pane=\(pane) rh=\(rh)"
                        continue
                    }
                    let count = range.upperBound - range.lowerBound + 1
                    let expected = min(drawn, 128)
                    if count != expected {
                        pitchFails += 1
                        pitchFirst = pitchFirst ?? "row count \(count) != \(expected) (drawn \(drawn)) focus=\(focus) pane=\(pane) rh=\(rh)"
                    }
                }
            }
        }
        tk.expect(pitchFails == 0, "visiblePitchRange/drawnRowCount degenerate sweep clean",
                  pitchFirst ?? "ok")

        // resizeHandleWidth + snap: degenerate note widths / grids.
        var handleFails = 0
        var handleFirst: String?
        for w in [CGFloat(-100), -1, 0, 0.5, 1, 10, 1e6, CGFloat.greatestFiniteMagnitude / 8] {
            let h = PianoRollLayout.resizeHandleWidth(noteWidth: w)
            if !h.isFinite || h.isNaN || h < 0 {
                handleFails += 1
                handleFirst = handleFirst ?? "handle bad at \(w): \(h)"
            } else if w > 0 && h > w + 1e-9 {
                handleFails += 1
                handleFirst = handleFirst ?? "handle \(h) > note \(w)"
            } else if w <= 0 && h != 0 {
                handleFails += 1
                handleFirst = handleFirst ?? "handle \(h) for non-positive \(w)"
            }
        }
        for grid in [-1.0, 0.0, 0.0625, 1.0, 1e6] {
            for raw in [-5.0, 0.0, 0.3, 1.37, 1e5] {
                let s = PianoRollLayout.snap(raw, to: grid)
                if !s.isFinite || s.isNaN {
                    handleFails += 1
                    handleFirst = handleFirst ?? "snap NaN raw \(raw) grid \(grid)"
                }
            }
        }
        tk.expect(handleFails == 0, "handle/snap degenerate sweep clean",
                  handleFirst ?? "ok")

        // Seeded cloud over fitBandHeights (valid call-site domain) + visiblePitchRange.
        var rng = SeededRNG(seed: 0xAC19_BEEF)
        var layoutFails = 0
        var layoutFirst: String?
        for trial in 0..<80 {
            let expanded = rng.nextBool()
            let floor = expanded ? workspaceMinExpanded : workspaceMinCollapsed
            let avail = CGFloat(rng.nextDouble(in: Double(floor)...2_000))
            let minA = CGFloat(rng.nextDouble(in: Double(callSiteMinArr)...Double(callSiteMinArr + 80)))
            let minR = CGFloat(rng.nextDouble(in: Double(callSiteMinRoll)...Double(callSiteMinRoll + 80)))
            let prefA = CGFloat(rng.nextDouble(in: Double(minA)...800))
            let prefR = CGFloat(rng.nextDouble(in: Double(minR)...800))
            let fit = PianoRollLayout.fitBandHeights(
                availableHeight: avail,
                rulerHeight: rulerH,
                dividerHeight: dividerH,
                rollExpanded: expanded,
                preferredArrangement: prefA,
                preferredRoll: prefR,
                minArrangement: minA,
                minRoll: minR
            )
            if !fit.arrangement.isFinite || fit.arrangement.isNaN || fit.arrangement < 0
                || !fit.roll.isFinite || fit.roll.isNaN || fit.roll < 0 {
                layoutFails += 1
                layoutFirst = layoutFirst ?? "trial \(trial): bad fit \(fit)"
                continue
            }
            let chrome = expanded ? rulerH + dividerH : rulerH
            let budget = max(0, avail - chrome)
            if fit.arrangement + fit.roll > budget + 1e-4 {
                layoutFails += 1
                layoutFirst = layoutFirst ?? "trial \(trial): stack \(fit.arrangement + fit.roll) > budget \(budget)"
                continue
            }
            // Row count vs height on the fitted roll pane (and positive panes).
            let pane = expanded
                ? max(0, fit.roll - PianoRollLayout.snapToolbarHeight)
                : CGFloat(rng.nextDouble(in: Double(PianoRollLayout.rowHeight)...4_000))
            let rh = PianoRollLayout.rowHeight
            let focus = rng.nextInt(in: 0...127)
            let drawn = PianoRollLayout.drawnRowCount(paneHeight: pane, rowHeight: rh)
            let range = PianoRollLayout.visiblePitchRange(
                focusPitch: focus, paneHeight: pane, rowHeight: rh)
            let count = range.upperBound - range.lowerBound + 1
            if drawn < 1 || count != min(drawn, 128)
                || range.lowerBound < 0 || range.upperBound > 127
                || range.lowerBound > range.upperBound {
                layoutFails += 1
                layoutFirst = layoutFirst ?? "trial \(trial): drawn \(drawn) range \(range) count \(count)"
            }
        }
        tk.expect(layoutFails == 0, "AC19 layout seeded cloud clean",
                  layoutFirst ?? "80 trials ok")
    }

}

/// Plan every MIDI clip the way `Transport.play` does for one shot from `playFromBeat`.
@MainActor
private func acPlanArrangementMIDI(
    project: Project,
    playFromBeat: Double,
    secondsPerBeat: Double
) -> [PlannedMIDINote] {
    var out: [PlannedMIDINote] = []
    for track in project.tracks {
        for clip in track.clips where clip.kind == .midi {
            out += Transport.planMIDINotes(
                notes: clip.midiNotes ?? [],
                clipStartBeat: clip.startBeat,
                clipLengthBeats: clip.lengthBeats,
                playFromBeat: playFromBeat,
                secondsPerBeat: secondsPerBeat
            )
        }
    }
    return out
}

/// Issues if planned MIDI events have non-finite times or off before on.
/// Loop bounds are not checked: the plan may extend past a loop end; wrap is stop+reschedule.
private func acPlanWellFormedIssues(_ planned: [PlannedMIDINote]) -> [String] {
    var issues: [String] = []
    for (i, ev) in planned.enumerated() {
        if !ev.onSeconds.isFinite || !ev.offSeconds.isFinite {
            issues.append("ev\(i) non-finite times")
            continue
        }
        if ev.offSeconds + 1e-12 < ev.onSeconds {
            issues.append("ev\(i) off < on")
        }
    }
    return issues
}

/// Random project with positive clip lengths, non-negative starts, and notes that start
/// at non-negative beats. Notes need not fit inside clip lengthBeats (that is a playback
/// window, not a storage bound); seeds still place them inside for variety.
private func acFuzzRandomProject(rng: inout SeededRNG) -> Project {
    let trackCount = rng.nextInt(in: 2...4)
    var tracks: [Track] = []
    // Guarantee at least one instrument and one audio track so kind-mismatch moves exist.
    for t in 0..<trackCount {
        let kind: TrackKind
        if t == 0 { kind = .instrument }
        else if t == 1 { kind = .audio }
        else { kind = rng.nextBool() ? .instrument : .audio }
        var track = Track(
            id: rng.nextUUID(),
            kind: kind,
            name: "ACFuzz T\(t)",
            volume: rng.nextDouble(in: 0...1),
            pan: rng.nextDouble(in: -1...1),
            mute: false,
            solo: false,
            colorIndex: rng.nextInt(in: 0...7),
            instrument: kind == .instrument ? .grandPiano : nil,
            clips: []
        )
        let clipCount = rng.nextInt(in: 0...3)
        for c in 0..<clipCount {
            let start = rng.nextDouble(in: 0...24)
            // Keep length clearly above the model floor so splits have room.
            let length = rng.nextDouble(in: 1.0...12.0)
            if kind == .instrument {
                let noteCount = rng.nextInt(in: 0...5)
                var notes: [Note] = []
                for _ in 0..<noteCount {
                    // Strictly inside [0, length): leave a tiny margin so start < length.
                    let maxStart = max(length - 0.05, 0.01)
                    let nStart = rng.nextDouble(in: 0...maxStart)
                    let nLen = rng.nextDouble(in: 0.0625...2.0)
                    notes.append(Note(
                        id: rng.nextUUID(),
                        startBeat: nStart,
                        lengthBeats: nLen,
                        pitch: rng.nextInt(in: 0...127),
                        velocity: rng.nextInt(in: 1...127)
                    ))
                }
                track.clips.append(Clip(
                    id: rng.nextUUID(),
                    kind: .midi,
                    name: "M\(c)",
                    startBeat: start,
                    lengthBeats: length,
                    midiNotes: notes
                ))
            } else {
                track.clips.append(Clip(
                    id: rng.nextUUID(),
                    kind: .audio,
                    name: "A\(c)",
                    startBeat: start,
                    lengthBeats: length,
                    mediaFile: "fuzz-\(t)-\(c).caf"
                ))
            }
        }
        tracks.append(track)
    }
    return Project(
        id: rng.nextUUID(),
        title: "ACFuzz",
        tempoBPM: Double(rng.nextInt(in: 60...180)),
        key: nil,
        timeSignature: .common,
        tracks: tracks,
        masterVolume: 0.85,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private enum ACFuzzOp: Int {
    case moveClipToTrack = 0
    case resizeClip = 1
    case splitClip = 2
    case duplicateClip = 3
}

/// Apply one random clip op. Invalid targets / rejects are allowed; they leave the project
/// unchanged. Successful ops may expose invariant defects (those stay failing).
private func acFuzzApplyRandomOp(to project: inout Project, rng: inout SeededRNG) {
    let op = ACFuzzOp(rawValue: rng.nextInt(in: 0...3))!
    let allClips: [(trackIndex: Int, clip: Clip)] = project.tracks.enumerated().flatMap { ti, t in
        t.clips.map { (ti, $0) }
    }
    guard !allClips.isEmpty else { return }

    switch op {
    case .moveClipToTrack:
        let pick = rng.pick(allClips)
        let dest = rng.nextInt(in: 0...(max(project.tracks.count, 1) + 1)) // sometimes OOB
        let start = rng.nextBool() ? rng.nextDouble(in: 0...32) : Double(rng.nextInt(in: -2...4))
        _ = try? project.moveClip(id: pick.clip.id, toTrackIndex: dest, startBeat: start)

    case .resizeClip:
        let pick = rng.pick(allClips)
        // Mix legal lengths, sub-minimum (floored), zero, and negative.
        let length: Double
        switch rng.nextInt(in: 0...5) {
        case 0: length = 0
        case 1: length = -rng.nextDouble(in: 0.01...2)
        case 2: length = rng.nextDouble(in: 0.01...(Project.minimumClipLengthBeats))
        default: length = rng.nextDouble(in: Project.minimumClipLengthBeats...16)
        }
        _ = try? project.resizeClip(id: pick.clip.id, toLengthBeats: length)

    case .splitClip:
        let midi = allClips.filter { $0.clip.kind == .midi && $0.clip.lengthBeats > 0.25 }
        guard let pick = midi.isEmpty ? nil : rng.pick(midi) else { return }
        let edge = rng.nextInt(in: 0...5)
        let playhead: Double
        switch edge {
        case 0: playhead = pick.clip.startBeat // exact start (reject)
        case 1: playhead = pick.clip.startBeat + pick.clip.lengthBeats // exact end (reject)
        default:
            let frac = rng.nextDouble(in: 0.05...0.95)
            playhead = pick.clip.startBeat + frac * pick.clip.lengthBeats
        }
        _ = try? project.splitClip(id: pick.clip.id, atArrangementBeat: playhead)

    case .duplicateClip:
        let pick = rng.pick(allClips)
        _ = try? project.duplicateClip(id: pick.clip.id)
    }
}

/// Returns a human-readable failure reason, or nil when all invariants hold.
///
/// A note with startBeat at or past clip.lengthBeats is a legitimate hidden tail:
/// lengthBeats is a playback window, not a container. Transport.planMIDINotes drops
/// those notes at playback. Pruning them on resize would destroy user music, so that
/// is deliberately not an invariant here.
private func acClipOpsInvariantFailure(_ project: Project) -> String? {
    var clipIDs = Set<UUID>()
    for (ti, track) in project.tracks.enumerated() {
        for (ci, clip) in track.clips.enumerated() {
            if clip.startBeat < 0 {
                return "track \(ti) clip \(ci): startBeat \(clip.startBeat) < 0"
            }
            if clip.lengthBeats <= 0 {
                return "track \(ti) clip \(ci): lengthBeats \(clip.lengthBeats) <= 0"
            }
            if clipIDs.contains(clip.id) {
                return "duplicate clip id \(clip.id.uuidString) at track \(ti) clip \(ci)"
            }
            clipIDs.insert(clip.id)

            var noteIDs = Set<UUID>()
            for (ni, note) in (clip.midiNotes ?? []).enumerated() {
                if note.startBeat < 0 {
                    return "track \(ti) clip \(ci) note \(ni): startBeat \(note.startBeat) < 0"
                }
                if noteIDs.contains(note.id) {
                    return "track \(ti) clip \(ci): duplicate note id \(note.id.uuidString)"
                }
                noteIDs.insert(note.id)
            }
        }
    }
    return nil
}

/// Encode → decode → re-encode must be byte-identical (equal project after JSON round trip).
private func acJSONRoundTripFailure(_ project: Project) -> String? {
    do {
        let data = try project.jsonData()
        let back = try Project.fromJSON(data)
        let data2 = try back.jsonData()
        if data != data2 {
            return "JSON round-trip re-encode mismatch (len \(data.count) vs \(data2.count))"
        }
        return nil
    } catch {
        return "JSON round-trip error: \(error)"
    }
}
