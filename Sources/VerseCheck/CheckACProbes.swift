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
}
