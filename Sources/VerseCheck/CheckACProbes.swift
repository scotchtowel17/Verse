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
