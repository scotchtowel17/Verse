import Foundation
import VerseModel
import VerseEngine
import VersePersistence
import VerseAI
import VerseAppCore

// MARK: - Step V1: undo round-trip property test

/// Any sequence of N undo-recording operations followed by N undos must restore the project
/// exactly (serialised JSON identity). Then N redos must restore the final state. Stack depth
/// must equal the number of recorded operations.
func runUndoRoundTripChecks(_ tk: TestKit) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { runUndoRoundTripOnMain(tk) }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { runUndoRoundTripOnMain(tk) }
        }
    }
}

@MainActor
private func runUndoRoundTripOnMain(_ tk: TestKit) {
    let trialCount = 50
    let minOps = 10
    let seed: UInt64 = 0x51EED0_01

    tk.suite("V1 undo round-trip property (seed 0x51EED001, \(trialCount)×≥\(minOps) ops)") {
        var rng = SeededRNG(seed: seed)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerseCheck-V1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = AppStore(recoveryBaseDir: dir)
        var trialsOK = 0
        var firstFailure: String?

        for trial in 0..<trialCount {
            store.newProject()
            seedProjectForUndoRoundTrip(store, rng: &rng)

            var snapshots: [Data] = []
            do {
                snapshots.append(try store.project.jsonData())
            } catch {
                firstFailure = firstFailure ?? "trial \(trial): initial json encode failed: \(error)"
                continue
            }

            var recorded = 0
            var attempts = 0
            let maxAttempts = 200
            while recorded < minOps && attempts < maxAttempts {
                attempts += 1
                let before = snapshots[snapshots.count - 1]
                applyRandomUndoOp(store, rng: &rng)
                // Ensure continuous gestures never leak into the next op.
                store.endPianoRollGesture()
                store.endArrangementGesture()

                guard opRecordedUndo(store, beforeJSON: before) else { continue }

                let after: Data
                do {
                    after = try store.project.jsonData()
                } catch {
                    firstFailure = firstFailure ??
                        "trial \(trial) op \(recorded): post-op json encode failed: \(error)"
                    break
                }
                snapshots.append(after)
                recorded += 1
            }

            if recorded < minOps {
                firstFailure = firstFailure ??
                    "trial \(trial): only recorded \(recorded)/\(minOps) ops after \(attempts) attempts"
                continue
            }

            let n = recorded
            // Depth: exactly N undos until empty.
            var undoSteps = 0
            var depthOK = true
            while store.canUndo {
                store.undo()
                undoSteps += 1
                if undoSteps > n + 5 {
                    depthOK = false
                    break
                }
            }
            if !depthOK || undoSteps != n {
                firstFailure = firstFailure ??
                    "trial \(trial): undo depth \(undoSteps) != recorded \(n)"
                // Reset store for next trial.
                store.newProject()
                continue
            }
            // After full undo we are at snapshots[0]. Re-walk with redos for the round-trip
            // checks: first re-apply all ops via redo, then undo again checking each step.
            // We already undid fully; redo forward checking snapshots[1]...[n], then undo
            // back checking snapshots[n-1]...[0].
            var redoOK = true
            for i in 1...n {
                guard store.canRedo else {
                    redoOK = false
                    firstFailure = firstFailure ??
                        "trial \(trial): canRedo false at redo step \(i)/\(n)"
                    break
                }
                store.redo()
                let got: Data
                do {
                    got = try store.project.jsonData()
                } catch {
                    redoOK = false
                    firstFailure = firstFailure ??
                        "trial \(trial): redo \(i) encode failed: \(error)"
                    break
                }
                if got != snapshots[i] {
                    redoOK = false
                    firstFailure = firstFailure ??
                        "trial \(trial): redo step \(i)/\(n) project JSON mismatch " +
                        "(bytes \(got.count) vs \(snapshots[i].count); " +
                        "\(jsonDiffHint(got, snapshots[i])))"
                    break
                }
            }
            if !redoOK {
                store.newProject()
                continue
            }

            var undoOK = true
            for i in stride(from: n, through: 1, by: -1) {
                guard store.canUndo else {
                    undoOK = false
                    firstFailure = firstFailure ??
                        "trial \(trial): canUndo false at undo step from \(i)"
                    break
                }
                store.undo()
                let got: Data
                do {
                    got = try store.project.jsonData()
                } catch {
                    undoOK = false
                    firstFailure = firstFailure ??
                        "trial \(trial): undo to \(i - 1) encode failed: \(error)"
                    break
                }
                if got != snapshots[i - 1] {
                    undoOK = false
                    firstFailure = firstFailure ??
                        "trial \(trial): undo from op \(i) project JSON mismatch vs snapshot \(i - 1) " +
                        "(bytes \(got.count) vs \(snapshots[i - 1].count); " +
                        "\(jsonDiffHint(got, snapshots[i - 1])))"
                    break
                }
            }
            if !undoOK {
                store.newProject()
                continue
            }

            // Final: redo all the way and match the last snapshot again.
            var finalOK = true
            for i in 1...n {
                store.redo()
                let got: Data
                do {
                    got = try store.project.jsonData()
                } catch {
                    finalOK = false
                    firstFailure = firstFailure ??
                        "trial \(trial): final redo \(i) encode failed: \(error)"
                    break
                }
                if got != snapshots[i] {
                    finalOK = false
                    firstFailure = firstFailure ??
                        "trial \(trial): final redo \(i) mismatch"
                    break
                }
            }
            if finalOK && !store.canRedo && store.canUndo {
                trialsOK += 1
            } else if finalOK {
                // Stack ends with N undos available, no redos.
                if store.canRedo {
                    firstFailure = firstFailure ??
                        "trial \(trial): expected empty redo stack after full redo"
                } else if !store.canUndo {
                    firstFailure = firstFailure ??
                        "trial \(trial): expected undo available after full redo"
                } else {
                    trialsOK += 1
                }
            }
        }

        tk.expectEqual(trialsOK, trialCount,
                       "\(trialsOK)/\(trialCount) trials passed full undo/redo JSON round-trip")
        if let firstFailure {
            tk.expect(false, "V1 first failure detail", firstFailure)
        } else {
            tk.expect(true, "V1 no trial failures")
        }
    }
}

// MARK: - Helpers

/// Serialised-JSON identity: did undoing once restore `beforeJSON`? If so this op recorded.
@MainActor
private func opRecordedUndo(_ store: AppStore, beforeJSON: Data) -> Bool {
    guard store.canUndo else { return false }
    store.undo()
    let restored: Data
    do {
        restored = try store.project.jsonData()
    } catch {
        store.redo()
        return false
    }
    let matched = restored == beforeJSON
    store.redo()
    return matched
}

/// Short hint when two JSON blobs differ (first differing key path is not parsed; show prefixes).
private func jsonDiffHint(_ a: Data, _ b: Data) -> String {
    let sa = String(data: a, encoding: .utf8) ?? "<bin \(a.count)>"
    let sb = String(data: b, encoding: .utf8) ?? "<bin \(b.count)>"
    if sa == sb { return "equal as UTF-8 (unexpected)" }
    let maxLen = 120
    // Find first char difference.
    let ac = Array(sa)
    let bc = Array(sb)
    var i = 0
    while i < ac.count && i < bc.count && ac[i] == bc[i] { i += 1 }
    let aSlice = String(ac[Swift.max(0, i - 20)..<Swift.min(ac.count, i + maxLen)])
    let bSlice = String(bc[Swift.max(0, i - 20)..<Swift.min(bc.count, i + maxLen)])
    return "diff@\(i) got…\(aSlice)… want…\(bSlice)…"
}

/// Build a small deterministic project with enough structure for every undo-recording API.
@MainActor
private func seedProjectForUndoRoundTrip(_ store: AppStore, rng: inout SeededRNG) {
    // Fixed timestamps so JSON comparisons are not polluted by wall-clock encoding.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var project = Project(
        id: rng.nextUUID(),
        title: "V1-\(rng.nextInt(in: 0...9999))",
        tempoBPM: Double(rng.nextInt(in: 80...140)),
        key: KeySignature(tonic: .C, mode: .major),
        timeSignature: .common,
        tracks: [],
        masterVolume: 0.85,
        createdAt: t0,
        modifiedAt: t0
    )

    // Two instrument tracks + one audio track so cross-track and delete ops have room.
    let inst0 = Track(
        id: rng.nextUUID(),
        kind: .instrument,
        name: "Lead",
        instrument: .grandPiano,
        clips: [
            Clip(
                id: rng.nextUUID(),
                kind: .midi,
                name: "Phrase A",
                startBeat: 0,
                lengthBeats: 8,
                midiNotes: [
                    Note(id: rng.nextUUID(), startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100),
                    Note(id: rng.nextUUID(), startBeat: 1, lengthBeats: 0.5, pitch: 64, velocity: 90),
                    Note(id: rng.nextUUID(), startBeat: 2, lengthBeats: 1, pitch: 67, velocity: 95),
                ]
            ),
            Clip(
                id: rng.nextUUID(),
                kind: .midi,
                name: "Phrase B",
                startBeat: 8,
                lengthBeats: 4,
                midiNotes: [
                    Note(id: rng.nextUUID(), startBeat: 0, lengthBeats: 2, pitch: 72, velocity: 80),
                ]
            ),
        ]
    )
    let inst1 = Track(
        id: rng.nextUUID(),
        kind: .instrument,
        name: "Bass",
        instrument: Instrument(program: 32, bankMSB: 121, bankLSB: 0),
        clips: [
            Clip(
                id: rng.nextUUID(),
                kind: .midi,
                name: "Bass line",
                startBeat: 0,
                lengthBeats: 8,
                midiNotes: [
                    Note(id: rng.nextUUID(), startBeat: 0, lengthBeats: 2, pitch: 36, velocity: 100),
                    Note(id: rng.nextUUID(), startBeat: 4, lengthBeats: 2, pitch: 41, velocity: 100),
                ]
            )
        ]
    )
    let audio = Track(
        id: rng.nextUUID(),
        kind: .audio,
        name: "Audio 1",
        clips: [
            Clip(
                id: rng.nextUUID(),
                kind: .audio,
                name: "Take",
                startBeat: 0,
                lengthBeats: 4,
                mediaFile: "seed-take.wav"
            )
        ]
    )
    project.tracks = [inst0, inst1, audio]
    store.project = project
    store.activeTrackID = inst0.id
    store.rollTrackID = inst0.id
    store.pianoRollClipID = inst0.clips[0].id
    store.showPianoRoll = true
}

// MARK: - Random ops (everything that records undo)

@MainActor
private func applyRandomUndoOp(_ store: AppStore, rng: inout SeededRNG) {
    // 0…17 covers the plan’s operation surface.
    let choice = rng.nextInt(in: 0...17)
    switch choice {
    case 0:
        store.addInstrumentTrack()
    case 1:
        store.addAudioTrack()
    case 2:
        // Prefer deleting a non-last track; no-op when only one remains.
        if store.project.tracks.count > 1 {
            let idx = rng.nextInt(in: 0...(store.project.tracks.count - 1))
            // Keep at least one instrument track when possible so note ops keep working.
            let id = store.project.tracks[idx].id
            store.deleteTrack(id)
        }
    case 3:
        if let preset = SoundBank.presets.isEmpty ? nil : SoundBank.presets[
            rng.nextInt(in: 0...(SoundBank.presets.count - 1))
        ] {
            let tid = store.project.tracks.first(where: { $0.kind == .instrument })?.id
                ?? store.activeTrackID
            store.selectPreset(preset, for: tid)
        }
    case 4:
        store.setTempo(Double(rng.nextInt(in: 40...240)))
    case 5:
        let tonic = Tonic.allCases[rng.nextInt(in: 0...(Tonic.allCases.count - 1))]
        let mode: Mode = rng.nextBool() ? .major : .minor
        store.setKey(tonic: tonic, mode: mode)
    case 6:
        ensurePianoRollOpen(store)
        let pitch = rng.nextInt(in: 36...84)
        let start = rng.nextDouble(in: 0...6)
        let len = rng.nextDouble(in: 0.125...2)
        _ = store.pianoRollAddNote(pitch: pitch, startBeat: start, lengthBeats: len)
    case 7:
        // Move note gesture.
        ensurePianoRollOpen(store)
        guard let note = firstNote(inOpenClip: store) else { return }
        store.beginPianoRollGesture(name: "Move Note")
        let newPitch = min(127, max(0, note.pitch + rng.nextInt(in: -5...5)))
        let newStart = max(0, note.startBeat + rng.nextDouble(in: -1...1))
        store.pianoRollMoveNote(id: note.id, toPitch: newPitch, toStartBeat: newStart)
        store.endPianoRollGesture()
    case 8:
        ensurePianoRollOpen(store)
        guard let note = firstNote(inOpenClip: store) else { return }
        store.beginPianoRollGesture(name: "Resize Note")
        let newLen = max(Project.minimumNoteLengthBeats, note.lengthBeats + rng.nextDouble(in: -0.5...1))
        store.pianoRollResizeNote(id: note.id, toLengthBeats: newLen)
        store.endPianoRollGesture()
    case 9:
        ensurePianoRollOpen(store)
        guard let note = firstNote(inOpenClip: store) else { return }
        store.pianoRollDeleteNote(id: note.id)
    case 10:
        ensurePianoRollOpen(store)
        let specs = (0..<rng.nextInt(in: 1...3)).map { _ in
            (pitch: rng.nextInt(in: 48...72),
             startBeat: rng.nextDouble(in: 0...4),
             lengthBeats: rng.nextDouble(in: 0.25...1),
             velocity: rng.nextInt(in: 60...120))
        }
        _ = store.pianoRollPasteNotes(specs)
    case 11:
        guard let clip = anyClip(store) else { return }
        store.beginArrangementGesture(name: "Move Clip")
        let newStart = max(0, clip.startBeat + rng.nextDouble(in: -2...4))
        store.arrangementMoveClip(id: clip.id, toStartBeat: newStart)
        store.endArrangementGesture()
    case 12:
        guard let clip = anyClip(store) else { return }
        store.beginArrangementGesture(name: "Resize Clip")
        let newLen = max(Project.minimumClipLengthBeats,
                         clip.lengthBeats + rng.nextDouble(in: -2...4))
        store.arrangementResizeClip(id: clip.id, toLengthBeats: newLen)
        store.endArrangementGesture()
    case 13:
        // Paste clips at playhead-ish position.
        guard let template = anyClip(store) else { return }
        let trackIdx: Int
        if let ti = store.project.tracks.firstIndex(where: {
            Project.trackAccepts(clipKind: template.kind, trackKind: $0.kind)
        }) {
            trackIdx = ti
        } else {
            return
        }
        let start = max(0, rng.nextDouble(in: 0...16))
        _ = store.arrangementPasteClips([(clip: template, startBeat: start, trackIndex: trackIdx)])
    case 14:
        guard let clip = anyClip(store) else { return }
        store.arrangementDeleteClips(ids: [clip.id])
    case 15:
        // Split a MIDI clip interior point.
        guard let clip = anyMIDIClip(store), clip.lengthBeats > Project.minimumClipLengthBeats * 2 else {
            return
        }
        let at = clip.startBeat + clip.lengthBeats * 0.5
        _ = store.arrangementSplitClip(id: clip.id, atArrangementBeat: at)
    case 16:
        // Move a MIDI clip to another instrument track (or audio→audio).
        guard let loc = anyClipLocation(store) else { return }
        let clip = store.project.tracks[loc.trackIndex].clips[loc.clipIndex]
        let candidates = store.project.tracks.indices.filter { ti in
            ti != loc.trackIndex &&
            Project.trackAccepts(clipKind: clip.kind, trackKind: store.project.tracks[ti].kind)
        }
        guard let dest = candidates.randomElement(using: &rng) ?? candidates.first else { return }
        store.beginArrangementGesture(name: "Move Clips")
        store.arrangementMoveClips([(id: clip.id, startBeat: clip.startBeat, trackIndex: dest)])
        store.endArrangementGesture()
    default:
        // Applied Claude patch (one undo group). Prefer a simple setTempo so it always validates.
        let fp = store.project.structuralFingerprint
        let bpm = rng.nextInt(in: 50...200)
        // Occasionally multi-op: tempo + rename so the group is non-trivial.
        let reply: String
        if rng.nextBool() {
            reply = """
            {"versePatch":{"schema":"verse-patch","version":1,"fingerprint":"\(fp)",
              "summary":"v1 fuzz",
              "ops":[{"op":"setTempo","bpm":\(bpm)}]}}
            """
        } else {
            reply = """
            {"versePatch":{"schema":"verse-patch","version":1,"fingerprint":"\(fp)",
              "summary":"v1 multi",
              "ops":[
                {"op":"setTempo","bpm":\(bpm)},
                {"op":"renameTrack","track":"T1","name":"Patched \(bpm)"}
              ]}}
            """
        }
        store.copilotReply = reply
        store.applyCopilotReply()
        // Commit only when preview succeeded; failed preview leaves the project untouched
        // and records no undo entry (opRecordedUndo will skip it).
        if store.pendingCopilotPreview != nil {
            store.commitCopilotPreview()
        }
    }
}

@MainActor
private func ensurePianoRollOpen(_ store: AppStore) {
    if let id = store.effectivePianoRollClipID, store.project.clipLocation(id: id) != nil {
        return
    }
    if let clip = anyMIDIClip(store) {
        store.openPianoRoll(clipID: clip.id)
    }
}

@MainActor
private func firstNote(inOpenClip store: AppStore) -> Note? {
    guard let clipID = store.effectivePianoRollClipID,
          let loc = store.project.clipLocation(id: clipID),
          let notes = store.project.tracks[loc.trackIndex].clips[loc.clipIndex].midiNotes,
          let note = notes.first else { return nil }
    return note
}

@MainActor
private func anyClip(_ store: AppStore) -> Clip? {
    for t in store.project.tracks {
        if let c = t.clips.first { return c }
    }
    return nil
}

@MainActor
private func anyMIDIClip(_ store: AppStore) -> Clip? {
    for t in store.project.tracks where t.kind == .instrument {
        if let c = t.clips.first(where: { $0.kind == .midi }) { return c }
    }
    return nil
}

@MainActor
private func anyClipLocation(_ store: AppStore) -> (trackIndex: Int, clipIndex: Int)? {
    for (ti, t) in store.project.tracks.enumerated() {
        if !t.clips.isEmpty { return (ti, 0) }
    }
    return nil
}

// Deterministic pick without SystemRandomNumberGenerator.
private extension Array {
    func randomElement(using rng: inout SeededRNG) -> Element? {
        guard !isEmpty else { return nil }
        return self[rng.nextInt(in: 0...(count - 1))]
    }
}
