import Foundation
import VerseModel
import VerseEngine
import VersePersistence
import VerseAppCore

/// AppStore undo-contract checks (Steps 3 and 6). Requires VerseAppCore so the app target
/// is no longer an untestable executable-only shell.
func runAppStoreChecks(_ tk: TestKit) {
    // AppStore is @MainActor. VerseCheck's process starts on the main thread; assumeIsolated
    // is correct for this harness without converting the whole executable to async.
    if Thread.isMainThread {
        MainActor.assumeIsolated { runAppStoreChecksOnMain(tk) }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { runAppStoreChecksOnMain(tk) }
        }
    }
}

@MainActor
private func makeTestStore() -> (AppStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("VerseCheck-AppStore-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = AppStore(recoveryBaseDir: dir)
    return (store, dir)
}

/// Count undo entries by undoing until empty, then redo the same number of times so the
/// store is restored. Labels are not needed; only depth.
@MainActor
private func undoDepth(of store: AppStore) -> Int {
    var depth = 0
    var restored: [Project] = []
    while store.canUndo {
        let before = store.project
        store.undo()
        restored.append(before)
        depth += 1
        // Safety: never spin forever if undo is a no-op.
        if depth > 200 { break }
    }
    for _ in restored.reversed() {
        store.redo()
    }
    return depth
}

/// Spin the main run loop until `predicate` is true or `timeout` seconds elapse.
/// Timeout is only a wait bound (not an asserted upper performance limit).
@discardableResult
@MainActor
private func waitUntilAppStore(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
    if predicate() { return true }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        if predicate() { return true }
    }
    return predicate()
}

@MainActor
private func runAppStoreChecksOnMain(_ tk: TestKit) {

    tk.suite("AppStore undo: discrete actions each push one labeled entry") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        tk.expect(!store.canUndo, "fresh store has empty undo")
        tk.expect(store.undoName == nil, "fresh store has no undoName")

        let trackCount0 = store.project.tracks.count
        store.addInstrumentTrack()
        tk.expectEqual(undoDepth(of: store), 1, "addInstrumentTrack pushes exactly one entry")
        tk.expectEqual(store.undoName, "Add Track", "addInstrumentTrack label")
        tk.expectEqual(store.project.tracks.count, trackCount0 + 1, "instrument track added")

        store.addAudioTrack()
        tk.expectEqual(undoDepth(of: store), 2, "addAudioTrack adds a second entry")
        tk.expectEqual(store.undoName, "Add Track", "addAudioTrack label")

        let toDelete = store.project.tracks.last!.id
        store.deleteTrack(toDelete)
        tk.expectEqual(undoDepth(of: store), 3, "deleteTrack adds a third entry")
        tk.expectEqual(store.undoName, "Delete Track", "deleteTrack label")

        store.setTempo(140)
        tk.expectEqual(undoDepth(of: store), 4, "setTempo adds one entry")
        tk.expectEqual(store.undoName, "Set Tempo", "setTempo label")
        tk.expectEqual(store.project.tempoBPM, 140, "tempo applied")

        store.setKey(tonic: .G, mode: .minor)
        tk.expectEqual(undoDepth(of: store), 5, "setKey adds one entry")
        tk.expectEqual(store.undoName, "Set Key", "setKey label")
        tk.expectEqual(store.project.key?.tonic, .G, "key tonic applied")
        tk.expectEqual(store.project.key?.mode, .minor, "key mode applied")

        guard let preset = SoundBank.presets.first else {
            tk.expect(false, "SoundBank has at least one preset")
            return
        }
        store.selectPreset(preset, for: store.activeTrackID)
        tk.expectEqual(undoDepth(of: store), 6, "selectPreset adds one entry")
        tk.expectEqual(store.undoName, "Select Preset", "selectPreset label")
        // Default name "Piano" is still auto-named on first selectPreset.
        tk.expectEqual(store.project.track(id: store.activeTrackID)?.name, preset.name,
                       "default track name auto-updated to preset name")
    }

    // MARK: - Phase F2: track name vs instrument identity

    tk.suite("AppStore F2: new project track resolves to Grand Piano preset") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = store.project.tracks[0]
        tk.expectEqual(track.name, "Piano", "seed track keeps its display name")
        guard let inst = track.instrument else {
            tk.expect(false, "seed track has an instrument")
            return
        }
        let matched = SoundBank.preset(matching: inst)
        tk.expect(matched != nil, "seed instrument matches a curated preset")
        tk.expectEqual(matched?.name, "Grand Piano", "new project resolves to Grand Piano")
        tk.expectEqual(store.presetSelectionKey(for: track), matched?.selectionKey ?? "",
                       "picker selection key is Grand Piano's program+bank")
        tk.expectEqual(store.currentPresetName, "Grand Piano",
                       "currentPresetName is instrument label, not track.name")
    }

    tk.suite("AppStore F2: renaming a track leaves instrument selection intact") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tid = store.activeTrackID
        guard let idx = store.project.trackIndex(id: tid),
              let before = store.project.tracks[idx].instrument else {
            tk.expect(false, "active track has instrument")
            return
        }
        let keyBefore = store.presetSelectionKey(for: store.project.tracks[idx])
        store.project.tracks[idx].name = "Lead Hook"
        let after = store.project.tracks[idx]
        tk.expectEqual(after.name, "Lead Hook", "name changed")
        tk.expectEqual(after.instrument, before, "instrument identity unchanged after rename")
        tk.expectEqual(store.presetSelectionKey(for: after), keyBefore,
                       "picker key unchanged after rename")
        tk.expectEqual(SoundBank.displayName(for: after.instrument), "Grand Piano",
                       "display name still Grand Piano")
    }

    tk.suite("AppStore F2: selectPreset preserves user-chosen track name") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tid = store.activeTrackID
        guard let idx = store.project.trackIndex(id: tid) else {
            tk.expect(false, "active track exists")
            return
        }
        store.project.tracks[idx].name = "My Lead"
        guard let warm = SoundBank.presets.first(where: { $0.name == "Warm Pad" })
                ?? SoundBank.presets.last else {
            tk.expect(false, "Warm Pad (or any) preset available")
            return
        }
        store.selectPreset(warm, for: tid)
        let track = store.project.track(id: tid)
        tk.expectEqual(track?.name, "My Lead", "user-renamed track keeps its name")
        tk.expectEqual(track?.instrument?.program, warm.program, "instrument program applied")
        tk.expectEqual(track?.instrument?.bankMSB, warm.bankMSB, "instrument bank applied")
        tk.expectEqual(store.currentPresetName, warm.name, "preset label reflects instrument")
    }

    tk.suite("AppStore F2: off-list GM program shows custom label") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tid = store.activeTrackID
        guard let idx = store.project.trackIndex(id: tid) else {
            tk.expect(false, "active track exists")
            return
        }
        // Program 9 (Glockenspiel) is deliberately not in the curated list.
        let custom = Instrument(sf2: SoundBank.generalUserGS, program: 9, bankMSB: 121, bankLSB: 0)
        store.project.tracks[idx].instrument = custom
        let track = store.project.tracks[idx]
        tk.expect(SoundBank.preset(matching: custom) == nil, "Glockenspiel is off-list")
        tk.expectEqual(SoundBank.displayName(for: custom), "Custom (program 9)",
                       "honest custom label")
        tk.expectEqual(store.presetSelectionKey(for: track), SoundBank.selectionKey(for: custom),
                       "selection key is program+bank even when custom")
        tk.expectEqual(store.currentPresetName, "Custom (program 9)",
                       "currentPresetName uses custom label")
    }

    // MARK: - Step M4: record arm has visible state

    tk.suite("AppStore M4: recordArmStatus armed vs capturing vs off") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        tk.expect(store.recordArmStatus == nil, "no status when unarmed")
        tk.expect(!store.isRecording, "not recording at start")

        store.startRecording()
        tk.expect(store.isRecording, "armed after startRecording")
        tk.expectEqual(store.recordArmStatus,
                       "Armed. Press play to record what you play.",
                       "armed status before play")
        tk.expect(!store.isPlaying, "not playing yet")

        store.startPlayback()
        tk.expect(store.isPlaying, "playing after startPlayback")
        tk.expectEqual(store.recordArmStatus,
                       "Recording what you play…",
                       "capturing status while armed and playing")

        store.stopRecording()
        tk.expect(!store.isRecording, "disarmed after stopRecording")
        tk.expect(store.recordArmStatus == nil, "no status after disarm")
        store.stopPlayback()
    }

    tk.suite("AppStore F2: default names auto-update; Instrument N is default") {
        tk.expect(AppStore.isDefaultTrackName("Piano"), "Piano is default")
        tk.expect(AppStore.isDefaultTrackName("Instrument 2"), "Instrument 2 is default")
        tk.expect(AppStore.isDefaultTrackName("Audio 3"), "Audio 3 is default")
        tk.expect(!AppStore.isDefaultTrackName("My Lead"), "user name is not default")
        tk.expect(!AppStore.isDefaultTrackName("Grand Piano"), "preset-style name is not default")
    }

    tk.suite("AppStore undo: setVolume / setPan never push (stack protection)") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.addInstrumentTrack()
        let tid = store.activeTrackID
        let depthAfterAdd = undoDepth(of: store)
        tk.expectEqual(depthAfterAdd, 1, "one entry before volume spam")
        tk.expectEqual(store.undoName, "Add Track", "label before volume spam")

        for i in 0..<200 {
            store.setVolume(Double(i % 100) / 100.0, tid)
            store.setPan((Double(i % 50) / 50.0) * 2 - 1, tid)
        }

        tk.expectEqual(undoDepth(of: store), 1, "200 volume/pan pairs push nothing")
        tk.expectEqual(store.undoName, "Add Track", "earlier AI-patch-critical entry still present")
        tk.expect(store.canUndo, "can still undo after volume spam")

        let tracksBeforeUndo = store.project.tracks.count
        store.undo()
        tk.expectEqual(store.project.tracks.count, tracksBeforeUndo - 1,
                       "undo still restores the Add Track snapshot")
        tk.expect(!store.canUndo, "stack empty after undoing the only entry")
    }

    tk.suite("AppStore undo: newProject clears the stack") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.addInstrumentTrack()
        store.setTempo(99)
        tk.expect(store.canUndo, "stack has entries before newProject")

        let oldTempo = store.project.tempoBPM
        store.newProject()
        tk.expect(!store.canUndo, "newProject clears undo")
        tk.expect(!store.canRedo, "newProject clears redo")
        tk.expect(store.undoName == nil && store.redoName == nil, "names nil after newProject")

        // Undo must not resurrect the previous document even if someone forced a call.
        store.undo()
        tk.expect(store.project.tempoBPM != oldTempo || store.project.tracks.count == 1,
                  "undo after newProject does not resurrect prior document")
        tk.expectEqual(store.project.tracks.count, Project.newUntitled().tracks.count,
                       "new project is a fresh untitled default")
    }

    tk.suite("AppStore undo: undo restores prior state and names swap correctly") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tempoBefore = store.project.tempoBPM
        store.setTempo(128)
        tk.expectEqual(store.undoName, "Set Tempo", "undoName after setTempo")
        tk.expect(store.redoName == nil, "no redo before undo")

        store.undo()
        tk.expectEqual(store.project.tempoBPM, tempoBefore, "undo restores prior tempo")
        tk.expectEqual(store.redoName, "Set Tempo", "redoName is the undone action")
        tk.expect(store.undoName == nil || store.undoName != "Set Tempo" || !store.canUndo,
                  "after single-entry undo, Set Tempo is no longer the undo target")
        tk.expect(!store.canUndo, "no further undo after single action")
        tk.expect(store.canRedo, "can redo after undo")

        store.redo()
        tk.expectEqual(store.project.tempoBPM, 128, "redo re-applies tempo")
        tk.expectEqual(store.undoName, "Set Tempo", "undoName restored after redo")
        tk.expect(store.redoName == nil, "redo empty after redo")
    }

    tk.suite("AppStore undo: copilot commit is one undo group for the whole patch") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let trackCountBefore = store.project.tracks.count
        let tempoBefore = store.project.tempoBPM
        let fp = store.project.structuralFingerprint
        // Multi-op patch: tempo + midi clip + note. Must be one undo group, not three.
        let reply = """
        {"versePatch":{"schema":"verse-patch","version":1,"fingerprint":"\(fp)",
          "summary":"test multi-op",
          "ops":[
            {"op":"setTempo","bpm":111},
            {"op":"addMidiClip","track":"T1","tempClipId":"c1","startBeat":0,"lengthBeats":4},
            {"op":"addNotes","track":"T1","clip":"c1",
             "notes":[{"startBeat":0,"lengthBeats":1,"pitch":60,"velocity":100}]}
          ]}}
        """
        store.copilotReply = reply
        store.applyCopilotReply()
        tk.expect(store.pendingCopilotPreview != nil, "preview sheet prepared")
        // Depth before commit must still be zero (preview does not record undo).
        tk.expectEqual(undoDepth(of: store), 0, "preview alone does not push undo")

        store.commitCopilotPreview()
        tk.expectEqual(store.project.tempoBPM, 111, "patch tempo applied")
        tk.expect(store.project.tracks[0].clips.count == 1, "midi clip applied")
        tk.expectEqual(undoDepth(of: store), 1, "whole patch is exactly one undo entry")
        tk.expectEqual(store.undoName, "Apply Claude Patch", "copilot undo label")

        store.undo()
        tk.expectEqual(store.project.tempoBPM, tempoBefore, "one undo restores pre-patch tempo")
        tk.expectEqual(store.project.tracks.count, trackCountBefore, "track count restored")
        tk.expect(store.project.tracks[0].clips.isEmpty, "clip removed by single undo")
        tk.expectEqual(store.redoName, "Apply Claude Patch", "redoName after undoing patch")
        tk.expect(!store.canUndo, "no further undo after undoing the single group")
    }

    // MARK: - Step G1: Effects truth

    tk.suite("AppStore effects: survive syncEngineToProject reconfigure") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        let tid = store.activeTrackID
        store.setEffect(.reverb, tid)
        tk.expectEqual(store.effect(for: tid), .reverb, "picker state is reverb before sync")
        tk.expectEqual(store.engineEffect(for: tid), .reverb, "engine node is reverb before sync")
        tk.expectEqual(
            AppStore.builtInEffect(fromInserts: store.project.track(id: tid)?.inserts ?? []),
            .reverb, "built-in reverb written into Track.inserts")

        // reconfigure tears down effect nodes; restore must re-apply from inserts.
        store.syncEngineToProject()
        tk.expectEqual(store.effect(for: tid), .reverb, "picker still shows reverb after sync")
        tk.expectEqual(store.engineEffect(for: tid), .reverb,
                       "engine still has reverb after reconfigure")
        tk.expect(store.effectMapOnlyNamesLiveTracks, "effects map only names live tracks after sync")
    }

    tk.suite("AppStore effects: map drops deleted tracks") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        store.addInstrumentTrack()
        let doomed = store.activeTrackID
        store.setEffect(.delay, doomed)
        tk.expectEqual(store.effect(for: doomed), .delay, "delay set on second track")
        store.deleteTrack(doomed)
        tk.expectEqual(store.effect(for: doomed), .none, "deleted track reports no effect")
        tk.expect(store.effectMapOnlyNamesLiveTracks,
                  "effects map never names a track that does not exist")
        store.syncEngineToProject()
        tk.expect(store.effectMapOnlyNamesLiveTracks,
                  "effects map still clean after syncEngineToProject")
    }

    tk.suite("AppStore effects: built-in survives save then open") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        let tid = store.activeTrackID
        store.setEffect(.distortion, tid)
        let pkg = dir.appendingPathComponent("fx.verse")
        try ProjectPackage.write(store.project, to: pkg, mediaSourceDir: nil)

        let loaded = try ProjectPackage.read(pkg)
        tk.expectEqual(AppStore.builtInEffect(fromInserts: loaded.tracks[0].inserts), .distortion,
                       "inserts round-trip through package as distortion")

        // Simulate open: assign project and sync (reconfigure + restore effects).
        store.project = loaded
        store.syncEngineToProject()
        let openedID = store.project.tracks[0].id
        tk.expectEqual(store.effect(for: openedID), .distortion, "picker restored after open")
        tk.expectEqual(store.engineEffect(for: openedID), .distortion,
                       "engine node restored after open")
    }

    tk.suite("AppStore effects: v1 project with no inserts opens unchanged") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var bare = Project.newUntitled()
        bare.title = "No FX"
        tk.expect(bare.tracks[0].inserts.isEmpty, "seed track has empty inserts")
        let pkg = dir.appendingPathComponent("bare.verse")
        try ProjectPackage.write(bare, to: pkg, mediaSourceDir: nil)

        let loaded = try ProjectPackage.read(pkg)
        tk.expectEqual(loaded.title, "No FX", "title unchanged")
        tk.expect(loaded.tracks[0].inserts.isEmpty, "inserts still empty after open")
        tk.expectEqual(loaded.schemaVersion, Schema.current, "schema stays at current (no bump)")

        store.project = loaded
        store.syncEngineToProject()
        tk.expectEqual(store.effect(for: loaded.tracks[0].id), .none,
                       "no effect claimed for empty inserts")
        tk.expectEqual(store.engineEffect(for: loaded.tracks[0].id), .none,
                       "engine has no insert for empty inserts")
    }

    // MARK: - Phase P2b / P3: piano roll layout + undo grouping

    tk.suite("Piano roll layout: pitch range covers notes (~3 octaves, no scroll needed)") {
        // Melody at C4–G4 (60–67): the live bug opened parked around C8/C9 with notes off-screen.
        let notes = (60...67).map { Note(startBeat: Double($0 - 60), lengthBeats: 0.5,
                                         pitch: $0, velocity: 100) }
        let range = PianoRollLayout.displayPitchRange(notes: notes)
        for n in notes {
            tk.expect(range.contains(n.pitch), "pitch \(n.pitch) is inside display range")
        }
        let span = range.upperBound - range.lowerBound
        tk.expect(span >= PianoRollLayout.minPitchSpan - 1,
                  "range is at least ~3 octaves (got span \(span))")
        tk.expect(range.upperBound <= 127 && range.lowerBound >= 0, "range stays in MIDI 0…127")
        // Mean of 60…67 is ~63; window should sit around mid-keyboard, not C8/C9.
        tk.expect(range.upperBound < 100, "window is not parked in the top octave")
        tk.expect(range.lowerBound > 30, "window is not parked in the bottom octave")

        let empty = PianoRollLayout.displayPitchRange(notes: [])
        tk.expect(empty.contains(60), "empty clip centres on middle C")
        tk.expect(empty.upperBound - empty.lowerBound >= PianoRollLayout.minPitchSpan - 1,
                  "empty clip still shows ~3 octaves")
    }

    tk.suite("AppStore piano roll: add/delete each push one labeled undo entry") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8, midiNotes: [])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)
        tk.expect(store.showPianoRoll, "piano roll opens")
        tk.expectEqual(store.pianoRollClipID, clip.id, "clip id stored")

        let id = store.pianoRollAddNote(pitch: 60, startBeat: 0, lengthBeats: 0.25)
        tk.expect(id != nil, "add returns note id")
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 1, "one note after add")
        tk.expectEqual(undoDepth(of: store), 1, "add is exactly one undo entry")
        tk.expectEqual(store.undoName, "Add Note", "add undo label")

        store.pianoRollDeleteNote(id: id!)
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 0, "note deleted")
        tk.expectEqual(undoDepth(of: store), 2, "delete adds a second entry")
        tk.expectEqual(store.undoName, "Delete Note", "delete undo label")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 1,
                       "undo delete restores the note")
        store.undo()
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 0,
                       "undo add removes the note")
    }

    tk.suite("AppStore piano roll: drag move is one undo for many updates") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [note])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)

        // Snapshot once, then stream updates like a drag (the setVolume failure mode).
        store.beginPianoRollGesture(name: "Move Note")
        for i in 1...80 {
            store.pianoRollMoveNote(id: note.id, toPitch: 60 + (i % 12),
                                    toStartBeat: Double(i) * 0.05)
        }
        store.endPianoRollGesture()

        tk.expectEqual(undoDepth(of: store), 1, "80 move updates are exactly one undo entry")
        tk.expectEqual(store.undoName, "Move Note", "move undo label")
        let after = store.project.tracks[0].clips[0].midiNotes![0]
        tk.expect(after.pitch != 60 || after.startBeat != 0, "note actually moved")

        store.undo()
        let restored = store.project.tracks[0].clips[0].midiNotes![0]
        tk.expectEqual(restored.pitch, 60, "one undo restores original pitch")
        tk.expectEqual(restored.startBeat, 0, "one undo restores original start")
    }

    tk.suite("AppStore piano roll: drag resize is one undo; move without begin is no-op") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = Note(startBeat: 0, lengthBeats: 1, pitch: 64, velocity: 100)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [note])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)

        // Without begin, continuous updates must not mutate (no silent undo-less edit).
        store.pianoRollMoveNote(id: note.id, toPitch: 72, toStartBeat: 2)
        store.pianoRollResizeNote(id: note.id, toLengthBeats: 3)
        let untouched = store.project.tracks[0].clips[0].midiNotes![0]
        tk.expectEqual(untouched.pitch, 64, "move without begin does not change pitch")
        tk.expectEqual(untouched.startBeat, 0, "move without begin does not change start")
        tk.expectEqual(untouched.lengthBeats, 1, "resize without begin does not change length")
        tk.expectEqual(undoDepth(of: store), 0, "no-op updates push nothing")

        store.beginPianoRollGesture(name: "Resize Note")
        for i in 1...50 {
            store.pianoRollResizeNote(id: note.id, toLengthBeats: 0.5 + Double(i) * 0.05)
        }
        // Sub-minimum positive values must stay visible (floored by the model).
        store.pianoRollResizeNote(id: note.id, toLengthBeats: 0.01)
        store.endPianoRollGesture()

        tk.expectEqual(undoDepth(of: store), 1, "50 resize updates are exactly one undo entry")
        tk.expectEqual(store.undoName, "Resize Note", "resize undo label")
        let resized = store.project.tracks[0].clips[0].midiNotes![0]
        tk.expectEqual(resized.lengthBeats, Project.minimumNoteLengthBeats,
                       "final sub-minimum length floored so note stays visible")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes![0].lengthBeats, 1,
                       "one undo restores original length")
    }

    tk.suite("AppStore piano roll: double begin does not double-snapshot") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [note])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)

        store.beginPianoRollGesture(name: "Move Note")
        store.beginPianoRollGesture(name: "Move Note") // accidental second begin
        store.pianoRollMoveNote(id: note.id, toPitch: 67, toStartBeat: 1)
        store.endPianoRollGesture()

        tk.expectEqual(undoDepth(of: store), 1, "double begin still one undo entry")
        tk.expectEqual(store.undoName, "Move Note", "label from first begin")
    }

    // MARK: - Phase P6: snap Off

    tk.suite("Piano roll layout: snap Off leaves values unrounded; grid snaps; new-note length") {
        // Move with snap Off: unrounded start.
        let freeStart = PianoRollLayout.snap(1.37, to: 0.0)
        tk.expectEqual(freeStart, 1.37, "snap Off move lands on unrounded start")

        // Resize with snap Off: unrounded length (caller still applies min floor).
        let freeLen = PianoRollLayout.snap(0.73, to: 0.0)
        tk.expectEqual(freeLen, 0.73, "snap Off resize produces unrounded length")

        // Snap on 1/8: both round to 0.5.
        tk.expectEqual(PianoRollLayout.snap(0.37, to: 0.5), 0.5, "1/8 snaps 0.37 → 0.5")
        tk.expectEqual(PianoRollLayout.snap(0.74, to: 0.5), 0.5, "1/8 snaps 0.74 → 0.5")
        tk.expectEqual(PianoRollLayout.snap(0.76, to: 0.5), 1.0, "1/8 snaps 0.76 → 1.0")

        // New note with snap Off uses remembered grid (default 1/16), not the 1/32 minimum.
        let offLength = PianoRollLayout.newNoteLengthBeats(snapBeats: 0, lastGridBeats: 0.25)
        tk.expectEqual(offLength, 0.25, "snap Off add uses last grid length, not 1/32 min")
        tk.expect(offLength > Project.minimumNoteLengthBeats,
                  "remembered length is longer than the 1/32 floor")

        // Last grid was 1/8 then user switched Off.
        let offAfterEighth = PianoRollLayout.newNoteLengthBeats(snapBeats: 0, lastGridBeats: 0.5)
        tk.expectEqual(offAfterEighth, 0.5, "snap Off add remembers last non-zero grid (1/8)")

        // Snap on: length is the grid unit.
        tk.expectEqual(PianoRollLayout.newNoteLengthBeats(snapBeats: 1.0, lastGridBeats: 0.25), 1.0,
                       "snap 1/4 add length is one quarter note")
        tk.expectEqual(PianoRollLayout.newNoteLengthBeats(snapBeats: 0.25, lastGridBeats: 0.25), 0.25,
                       "snap 1/16 add length is one sixteenth")

        // Minimum guard still holds with snap Off (raw length below floor).
        let floored = max(Project.minimumNoteLengthBeats, PianoRollLayout.snap(0.01, to: 0.0))
        tk.expectEqual(floored, Project.minimumNoteLengthBeats,
                       "min length guard holds with snap Off")
    }

    // MARK: - Phase P5: short notes keep a move body

    tk.suite("Piano roll layout: resize handle is proportional and never covers the whole note") {
        // Default snap 1/16 at beatWidth 56 → note is 14px; fixed 10px handle used to cover it.
        let shortNoteWidth: CGFloat = 0.25 * 56
        let handle = PianoRollLayout.resizeHandleWidth(noteWidth: shortNoteWidth)
        tk.expect(handle < shortNoteWidth * 0.5,
                  "short-note handle is under half the block (got \(handle) of \(shortNoteWidth))")
        tk.expectEqual(handle, shortNoteWidth * PianoRollLayout.resizeHandleFraction,
                       "short notes use fraction of width, not the fixed max")
        tk.expect(shortNoteWidth - handle > 0, "middle of short note remains for move")

        let longNoteWidth: CGFloat = 4 * 56
        let longHandle = PianoRollLayout.resizeHandleWidth(noteWidth: longNoteWidth)
        tk.expectEqual(longHandle, PianoRollLayout.resizeHandleMaxWidth,
                       "long notes cap at the fixed max edge width")

        tk.expectEqual(PianoRollLayout.resizeHandleWidth(noteWidth: 0), 0,
                       "zero-width note has no handle")
        // Formula from the plan: min(fixed, width * 0.3)
        for w: CGFloat in [6, 10, 14, 20, 56, 112] {
            let h = PianoRollLayout.resizeHandleWidth(noteWidth: w)
            let expected = min(PianoRollLayout.resizeHandleMaxWidth,
                               w * PianoRollLayout.resizeHandleFraction)
            tk.expectEqual(h, expected, "handle for width \(w) matches min(max, w*0.3)")
            tk.expect(h < w || w == 0, "handle never covers full width \(w)")
        }
    }

    // MARK: - Phase P4: integration

    tk.suite("AppStore piano roll: brand-new track opens by creating an empty MIDI clip") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Default project: one instrument track, no clips. This is the live usability gap.
        let track = store.project.tracks[0]
        tk.expectEqual(track.kind, TrackKind.instrument, "default track is instrument")
        tk.expectEqual(track.clips.count, 0, "brand-new project has no clips")

        store.openPianoRoll(forTrack: track.id)
        tk.expect(store.showPianoRoll, "piano roll opens from empty track")
        tk.expect(store.pianoRollClipID != nil, "clip id assigned")
        tk.expectEqual(store.project.tracks[0].clips.count, 1, "empty MIDI clip created")
        let clip = store.project.tracks[0].clips[0]
        tk.expectEqual(clip.kind, ClipKind.midi, "created clip is MIDI")
        tk.expectEqual(clip.midiNotes?.count ?? 0, 0, "created clip starts empty")
        tk.expectEqual(store.pianoRollClipID, clip.id, "roll points at the new clip")
        let expectedLen = Double(max(1, store.project.timeSignature.num) * 4)
        tk.expectEqual(clip.lengthBeats, expectedLen, "empty clip is 4 bars")
        tk.expectEqual(undoDepth(of: store), 1, "creating the clip is one undo entry")
        tk.expectEqual(store.undoName, "Add MIDI Clip", "create-clip undo label")

        // Drawing a note on the new clip works end-to-end.
        let noteID = store.pianoRollAddNote(pitch: 60, startBeat: 0, lengthBeats: 0.25)
        tk.expect(noteID != nil, "can draw on the newly created clip")
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 1, "note lands in clip")

        store.undo() // undo add note
        store.undo() // undo add clip
        tk.expectEqual(store.project.tracks[0].clips.count, 0, "undo remove empty clip")
        // Roll may still reference the old id; that is fine (clip gone → empty UI).
    }

    tk.suite("AppStore piano roll: forTrack reuses existing MIDI clip, no duplicate") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                            midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [existing]
        store.openPianoRoll(forTrack: store.project.tracks[0].id)
        tk.expectEqual(store.project.tracks[0].clips.count, 1, "no second clip created")
        tk.expectEqual(store.pianoRollClipID, existing.id, "opens the existing clip")
        tk.expectEqual(undoDepth(of: store), 0, "reuse path does not push undo")
    }

    tk.suite("AppStore piano roll: forTrack rejects audio tracks") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.addAudioTrack()
        let audioID = store.project.tracks.last!.id
        let clipsBefore = store.project.tracks.last!.clips.count
        store.openPianoRoll(forTrack: audioID)
        tk.expect(!store.showPianoRoll, "audio track does not open the roll")
        tk.expect(store.pianoRollClipID == nil, "no clip id for audio track")
        tk.expectEqual(store.project.tracks.last!.clips.count, clipsBefore,
                       "audio track is not given a MIDI clip")
    }

    tk.suite("AppStore piano roll: open roll reflects later project note changes (patch path)") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8, midiNotes: [])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count ?? 0, 0,
                       "roll opens on empty clip")

        // Simulate a Claude patch (or any external mutation) while the roll is open:
        // project is replaced in place; the roll reads live from store.project each render.
        var working = store.project
        let added = try! working.addNote(toClip: clip.id, pitch: 64, startBeat: 1,
                                         lengthBeats: 0.5, velocity: 100)
        store.project = working
        tk.expectEqual(store.pianoRollClipID, clip.id, "roll stays on the same clip")
        let liveNotes = store.project.tracks[0].clips[0].midiNotes ?? []
        tk.expectEqual(liveNotes.count, 1, "notes appear while roll is open")
        tk.expectEqual(liveNotes[0].id, added, "new note id is visible")
        tk.expectEqual(liveNotes[0].pitch, 64, "new note pitch is visible")
    }

    tk.suite("AppStore piano roll: playbackBeat holds scrubbed position when stopped") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        tk.expectEqual(store.playbackBeat, 0, "playhead starts at beat 0")
        store.scrubPlayhead(to: 3.5)
        tk.expectEqual(store.playbackBeat, 3.5, "scrubbed playhead is visible while stopped")
        tk.expect(!store.isPlaying, "scrub does not start playback")
    }

    // MARK: - Step S1: transport inside piano roll (pause / resume / scrub / no undo)

    tk.suite("AppStore S1: pause holds position; play resumes from there") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        // Seed a long MIDI clip so playback has room to advance.
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 32,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 16, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [clip]

        store.scrubPlayhead(to: 2.0)
        store.startPlayback()
        tk.expect(store.isPlaying, "playing after start from scrubbed beat")
        // Allow the playhead past the 0.12s lead so musical time has moved.
        let advanced = waitUntilAppStore(timeout: 1.5) { (store.playbackBeat ?? 0) > 2.15 }
        tk.expect(advanced, "playhead advanced past resume point while playing")

        let beforePause = store.playbackBeat ?? 0
        store.pausePlayback()
        tk.expect(!store.isPlaying, "paused")
        let held = store.playheadBeat
        tk.expect(held >= beforePause - 0.05,
                  "pause holds near the live beat (held \(held), was \(beforePause))")
        tk.expectEqual(store.playbackBeat, held, "playbackBeat reports held position while paused")

        store.startPlayback()
        tk.expect(store.isPlaying, "resumed after pause")
        // Immediately after resume, beat should be at (or very near) the held position, not 0.
        if let resumeBeat = store.playbackBeat {
            tk.expect(resumeBeat >= held - 0.05,
                      "resume starts from held beat, not zero (got \(resumeBeat), held \(held))")
            tk.expect(resumeBeat < held + 1.0,
                      "resume does not jump far ahead of held beat (got \(resumeBeat), held \(held))")
        } else {
            tk.expect(false, "playbackBeat non-nil while playing after resume")
        }
        store.pausePlayback()
    }

    tk.suite("AppStore S1: rewind returns to beat 0; distinct from pause") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        store.scrubPlayhead(to: 5.0)
        tk.expectEqual(store.playheadBeat, 5.0, "scrub set playhead")
        store.rewindToStart()
        tk.expectEqual(store.playheadBeat, 0, "rewind returns to beat 0")
        tk.expect(!store.isPlaying, "rewind leaves transport stopped")

        // Pause mid-play then rewind: position goes to 0, not the paused beat.
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 32,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 16, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [clip]
        store.startPlayback()
        _ = waitUntilAppStore(timeout: 1.0) { (store.playbackBeat ?? 0) > 0.2 }
        store.pausePlayback()
        tk.expect(store.playheadBeat > 0, "pause left playhead past zero")
        store.rewindToStart()
        tk.expectEqual(store.playheadBeat, 0, "rewind after pause returns to zero")
        tk.expect(!store.isPlaying, "still stopped after rewind")
    }

    tk.suite("AppStore S1: scrub while playing stops and sets playhead") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 32,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 16, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [clip]
        store.startPlayback()
        tk.expect(store.isPlaying, "playing before scrub")
        store.scrubPlayhead(to: 7.25)
        tk.expect(!store.isPlaying, "scrub stops playback")
        tk.expectEqual(store.playheadBeat, 7.25, "scrubbed position held")
        tk.expectEqual(store.playbackBeat, 7.25, "draw position matches scrub")
    }

    tk.suite("AppStore S1: transport actions never record undo") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        // One real edit so the stack is non-empty and we can detect accidental pushes.
        store.addInstrumentTrack()
        let depthBefore = undoDepth(of: store)
        tk.expect(depthBefore >= 1, "baseline undo depth after add track")

        store.scrubPlayhead(to: 4.0)
        store.startPlayback()
        store.pausePlayback()
        store.rewindToStart()
        store.scrubPlayhead(to: 1.5)
        store.togglePlay()
        store.togglePlay()

        let depthAfter = undoDepth(of: store)
        tk.expectEqual(depthAfter, depthBefore,
                       "play/pause/rewind/scrub/toggle must not push undo entries")
    }

    tk.suite("AppStore S1: play from non-zero playhead uses Transport from:") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 32,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 16, pitch: 60, velocity: 90)])
        store.project.tracks[0].clips = [clip]
        store.scrubPlayhead(to: 4.0)
        store.startPlayback()
        tk.expect(store.isPlaying, "playing")
        // During the scheduling lead, currentBeat reports the start beat (not zero).
        if let beat = store.playbackBeat {
            tk.expect(beat >= 3.9,
                      "play begins at scrubbed beat, not arrangement start (got \(beat))")
        } else {
            tk.expect(false, "playbackBeat while playing")
        }
        store.pausePlayback()
    }

    // MARK: - Step S2: selection helpers, group move, copy/paste, multi-delete

    tk.suite("Piano roll S2: marquee selects notes it touches") {
        let a = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let b = Note(startBeat: 2, lengthBeats: 0.5, pitch: 64, velocity: 100)
        let c = Note(startBeat: 4, lengthBeats: 1, pitch: 72, velocity: 100)
        let notes = [a, b, c]

        // Marquee over pitch 60–65 and beats 0–3: hits a and b, not c.
        let hit = PianoRollSelection.notesTouchingMarquee(
            notes: notes, beatA: 0, beatB: 3, pitchA: 60, pitchB: 65)
        tk.expectEqual(Set(hit), Set([a.id, b.id]), "marquee touches low chord notes")

        // Edge touch: marquee starts exactly at note end should not count as overlap
        // (half-open style: noteBeatHi > beatLo requires beatLo < end).
        let edge = PianoRollSelection.noteTouchesMarquee(
            note: a, beatA: 1, beatB: 2, pitchA: 60, pitchB: 60)
        tk.expect(!edge, "marquee starting at note end does not touch")

        // Touch at note start edge does hit.
        let startEdge = PianoRollSelection.noteTouchesMarquee(
            note: a, beatA: 0.5, beatB: 1.5, pitchA: 60, pitchB: 60)
        tk.expect(startEdge, "marquee overlapping note body touches")

        // Vertical line marquee (same beat, pitch span) still hits notes covering that beat.
        let vertical = PianoRollSelection.noteTouchesMarquee(
            note: a, beatA: 0.25, beatB: 0.25, pitchA: 59, pitchB: 61)
        tk.expect(vertical, "vertical marquee through note body touches")

        // Completely outside pitch range does not hit.
        let missPitch = PianoRollSelection.noteTouchesMarquee(
            note: a, beatA: 0, beatB: 1, pitchA: 70, pitchB: 72)
        tk.expect(!missPitch, "marquee on other pitches does not touch")
    }

    tk.suite("Piano roll S2: group move preserves formation or rejects whole") {
        let origins: [(pitch: Int, startBeat: Double)] = [
            (pitch: 60, startBeat: 0),
            (pitch: 64, startBeat: 0.5),
            (pitch: 67, startBeat: 1.0),
        ]
        let up = PianoRollSelection.applyGroupDelta(origins: origins, pitchDelta: 2, beatDelta: 1.0)
        tk.expect(up != nil, "in-range group move accepted")
        tk.expectEqual(up![0].pitch, 62, "primary pitch shifted")
        tk.expectEqual(up![1].pitch, 66, "chord interval preserved")
        tk.expectEqual(up![2].pitch, 69, "top of chord shifted")
        tk.expectEqual(up![0].startBeat, 1.0, "time delta applied")
        tk.expectEqual(up![1].startBeat, 1.5, "relative time preserved")
        tk.expectEqual(up![2].startBeat, 2.0, "relative time preserved on third")

        // Pitch out of range on any note rejects the whole group.
        let tooHigh = PianoRollSelection.applyGroupDelta(
            origins: origins, pitchDelta: 70, beatDelta: 0)
        tk.expect(tooHigh == nil, "pitch overflow rejects whole selection")

        let tooLow = PianoRollSelection.applyGroupDelta(
            origins: [(pitch: 1, startBeat: 0), (pitch: 60, startBeat: 1)],
            pitchDelta: -2, beatDelta: 0)
        tk.expect(tooLow == nil, "pitch underflow rejects whole selection")

        // Start before beat 0 rejects the whole group (no partial move).
        let beforeZero = PianoRollSelection.applyGroupDelta(
            origins: origins, pitchDelta: 0, beatDelta: -0.75)
        tk.expect(beforeZero == nil, "negative start rejects whole selection")

        // Boundary pitches still valid.
        let edge = PianoRollSelection.applyGroupDelta(
            origins: [(pitch: 0, startBeat: 0), (pitch: 127, startBeat: 1)],
            pitchDelta: 0, beatDelta: 0)
        tk.expect(edge != nil, "0 and 127 stay valid with zero delta")
    }

    tk.suite("Piano roll S2: paste offsets preserve relative starts at playhead") {
        let starts = [2.0, 2.5, 4.0]
        let pasted = PianoRollSelection.pasteStartBeats(
            clipboardStarts: starts, playheadLocalBeat: 8.0)
        tk.expectEqual(pasted, [8.0, 8.5, 10.0],
                       "earliest maps to playhead; others keep offsets")

        let empty = PianoRollSelection.pasteStartBeats(
            clipboardStarts: [], playheadLocalBeat: 3)
        tk.expectEqual(empty.count, 0, "empty clipboard yields empty paste starts")

        // Playhead at 0 with clipboard starting mid-clip.
        let atZero = PianoRollSelection.pasteStartBeats(
            clipboardStarts: [1.0, 3.0], playheadLocalBeat: 0)
        tk.expectEqual(atZero, [0.0, 2.0], "paste at beat 0 keeps spacing")
    }

    tk.suite("AppStore S2: multi-delete is one undo entry") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 1, lengthBeats: 1, pitch: 64, velocity: 100)
        let n3 = Note(startBeat: 2, lengthBeats: 1, pitch: 67, velocity: 100)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [n1, n2, n3])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)

        store.pianoRollDeleteNotes(ids: [n1.id, n2.id])
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 1,
                       "two notes deleted, one remains")
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?[0].id, n3.id,
                       "remaining note is the untouched one")
        tk.expectEqual(undoDepth(of: store), 1, "multi-delete is exactly one undo entry")
        tk.expectEqual(store.undoName, "Delete Notes", "multi-delete label")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 3,
                       "one undo restores both deleted notes")
    }

    tk.suite("AppStore S2: group move is one undo; rejects partial out-of-range") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let low = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let high = Note(startBeat: 0.5, lengthBeats: 1, pitch: 120, velocity: 100)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [low, high])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)

        store.beginPianoRollGesture(name: "Move Notes")
        // Valid group move: both up a whole step.
        for _ in 1...10 {
            store.pianoRollMoveNotes([
                (id: low.id, toPitch: 62, toStartBeat: 1.0),
                (id: high.id, toPitch: 122, toStartBeat: 1.5),
            ])
        }
        // Out-of-range for high (130): whole update rejected; notes stay at last valid.
        store.pianoRollMoveNotes([
            (id: low.id, toPitch: 70, toStartBeat: 2.0),
            (id: high.id, toPitch: 130, toStartBeat: 2.5),
        ])
        store.endPianoRollGesture()

        let after = store.project.tracks[0].clips[0].midiNotes!
        let lowAfter = after.first { $0.id == low.id }!
        let highAfter = after.first { $0.id == high.id }!
        tk.expectEqual(lowAfter.pitch, 62, "low kept last valid pitch (not partial 70)")
        tk.expectEqual(highAfter.pitch, 122, "high kept last valid pitch")
        tk.expectEqual(lowAfter.startBeat, 1.0, "low kept last valid start")
        tk.expectEqual(highAfter.startBeat, 1.5, "high kept last valid start")
        tk.expectEqual(undoDepth(of: store), 1, "many group updates are one undo entry")
        tk.expectEqual(store.undoName, "Move Notes", "group move label")

        store.undo()
        let restored = store.project.tracks[0].clips[0].midiNotes!
        tk.expectEqual(restored.first { $0.id == low.id }!.pitch, 60,
                       "one undo restores original pitches")
        tk.expectEqual(restored.first { $0.id == high.id }!.pitch, 120,
                       "one undo restores both notes")
    }

    tk.suite("AppStore S2: paste at playhead is one undo; leaves new notes") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = Clip(kind: .midi, name: "phrase", startBeat: 2, lengthBeats: 16,
                        midiNotes: [])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)
        store.scrubPlayhead(to: 6.0) // arrangement beat 6 → clip-local 4

        // Clipboard-like relative group: earliest at 0 offset after pasteStartBeats.
        let starts = PianoRollSelection.pasteStartBeats(
            clipboardStarts: [1.0, 1.5, 2.0], playheadLocalBeat: 4.0)
        tk.expectEqual(starts, [4.0, 4.5, 5.0], "playhead-local paste anchors")

        let ids = store.pianoRollPasteNotes([
            (pitch: 60, startBeat: starts[0], lengthBeats: 0.5, velocity: 100),
            (pitch: 64, startBeat: starts[1], lengthBeats: 0.5, velocity: 90),
            (pitch: 67, startBeat: starts[2], lengthBeats: 0.5, velocity: 80),
        ])
        tk.expectEqual(ids.count, 3, "paste returns three new ids")
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 3, "three notes in clip")
        tk.expectEqual(undoDepth(of: store), 1, "paste is exactly one undo entry")
        tk.expectEqual(store.undoName, "Paste Notes", "paste undo label")

        let pasted = store.project.tracks[0].clips[0].midiNotes!
        tk.expectEqual(pasted.map(\.startBeat).sorted(), [4.0, 4.5, 5.0],
                       "relative offsets preserved at playhead")
        tk.expectEqual(Set(pasted.map(\.id)), Set(ids), "returned ids match live notes")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count ?? 0, 0,
                       "one undo removes the whole paste")
    }

    tk.suite("AppStore S2: cut is one undo; single delete label still singular") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 1, lengthBeats: 1, pitch: 64, velocity: 100)
        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                        midiNotes: [n1, n2])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)

        store.pianoRollDeleteNotes(ids: [n1.id, n2.id], undoName: "Cut Notes")
        tk.expectEqual(store.undoName, "Cut Notes", "cut uses Cut Notes label")
        tk.expectEqual(undoDepth(of: store), 1, "cut is one undo entry")
        store.undo()

        store.pianoRollDeleteNotes(ids: [n1.id])
        tk.expectEqual(store.undoName, "Delete Note", "single delete stays singular")
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 1, "one note left")
    }

    // MARK: - Phase R2: arrangement view (move / resize undo grouping + layout)

    tk.suite("AppStore arrangement: drag move is one undo for many updates") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [clip]

        store.beginArrangementGesture(name: "Move Clip")
        for i in 1...80 {
            store.arrangementMoveClip(id: clip.id, toStartBeat: Double(i) * 0.05)
        }
        store.endArrangementGesture()

        tk.expectEqual(undoDepth(of: store), 1, "80 move updates are exactly one undo entry")
        tk.expectEqual(store.undoName, "Move Clip", "move undo label")
        let after = store.project.tracks[0].clips[0]
        tk.expect(after.startBeat != 0, "clip actually moved")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips[0].startBeat, 0,
                       "one undo restores original start")
    }

    tk.suite("AppStore arrangement: drag resize is one undo; move without begin is no-op") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = Clip(kind: .audio, name: "Take", startBeat: 0, lengthBeats: 4, mediaFile: "t.wav")
        store.project.tracks[0].clips = [clip]

        // Without begin, continuous updates must not mutate (no silent undo-less edit).
        store.arrangementMoveClip(id: clip.id, toStartBeat: 8)
        store.arrangementResizeClip(id: clip.id, toLengthBeats: 2)
        let untouched = store.project.tracks[0].clips[0]
        tk.expectEqual(untouched.startBeat, 0, "move without begin does not change start")
        tk.expectEqual(untouched.lengthBeats, 4, "resize without begin does not change length")
        tk.expectEqual(undoDepth(of: store), 0, "no-op updates push nothing")

        store.beginArrangementGesture(name: "Resize Clip")
        for i in 1...50 {
            store.arrangementResizeClip(id: clip.id, toLengthBeats: 0.5 + Double(i) * 0.05)
        }
        store.arrangementResizeClip(id: clip.id, toLengthBeats: 0.01)
        store.endArrangementGesture()

        tk.expectEqual(undoDepth(of: store), 1, "50 resize updates are exactly one undo entry")
        tk.expectEqual(store.undoName, "Resize Clip", "resize undo label")
        let resized = store.project.tracks[0].clips[0]
        tk.expectEqual(resized.lengthBeats, Project.minimumClipLengthBeats,
                       "final sub-minimum length floored so clip stays visible")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips[0].lengthBeats, 4,
                       "one undo restores original length")
    }

    tk.suite("AppStore arrangement: double begin does not double-snapshot") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 4, midiNotes: [])
        store.project.tracks[0].clips = [clip]

        store.beginArrangementGesture(name: "Move Clip")
        store.beginArrangementGesture(name: "Move Clip") // accidental second begin
        store.arrangementMoveClip(id: clip.id, toStartBeat: 3)
        store.endArrangementGesture()

        tk.expectEqual(undoDepth(of: store), 1, "double begin still one undo entry")
        tk.expectEqual(store.undoName, "Move Clip", "label from first begin")
        tk.expectEqual(store.project.tracks[0].clips[0].startBeat, 3, "clip moved")
    }

    tk.suite("Arrangement layout: resize handle is proportional and never covers the whole clip") {
        // Short clip (1/16 at beatWidth 28 → 7px): fixed 10px handle would swallow the body.
        let shortClipWidth: CGFloat = 0.25 * 28
        let handle = ArrangementLayout.resizeHandleWidth(clipWidth: shortClipWidth)
        tk.expect(handle < shortClipWidth * 0.5,
                  "short-clip handle is under half the block (got \(handle) of \(shortClipWidth))")
        tk.expectEqual(handle, shortClipWidth * ArrangementLayout.resizeHandleFraction,
                       "short clips use fraction of width, not the fixed max")
        tk.expect(shortClipWidth - handle > 0, "middle of short clip remains for move")

        let longClipWidth: CGFloat = 8 * 28
        let longHandle = ArrangementLayout.resizeHandleWidth(clipWidth: longClipWidth)
        tk.expectEqual(longHandle, ArrangementLayout.resizeHandleMaxWidth,
                       "long clips cap at the fixed max edge width")

        tk.expectEqual(ArrangementLayout.resizeHandleWidth(clipWidth: 0), 0,
                       "zero-width clip has no handle")
        for w: CGFloat in [6, 10, 14, 20, 56, 112] {
            let h = ArrangementLayout.resizeHandleWidth(clipWidth: w)
            let expected = min(ArrangementLayout.resizeHandleMaxWidth,
                               w * ArrangementLayout.resizeHandleFraction)
            tk.expectEqual(h, expected, "handle for width \(w) matches min(max, w*0.3)")
            tk.expect(h < w || w == 0, "handle never covers full width \(w)")
        }
    }

    tk.suite("Arrangement layout: contentBeats handles empty project and clip ends") {
        let empty = ArrangementLayout.contentBeats(tracks: [], beatsPerBar: 4)
        tk.expectEqual(empty, 16, "empty project shows at least 4 bars")

        let shortTrack = Track(kind: .instrument, name: "P",
                               instrument: .grandPiano,
                               clips: [Clip(kind: .midi, name: "c", startBeat: 0, lengthBeats: 2)])
        let short = ArrangementLayout.contentBeats(tracks: [shortTrack], beatsPerBar: 4)
        tk.expectEqual(short, 16, "short clips still pad to 4 bars")

        let longTrack = Track(kind: .instrument, name: "P",
                              instrument: .grandPiano,
                              clips: [Clip(kind: .midi, name: "c", startBeat: 20, lengthBeats: 8)])
        let long = ArrangementLayout.contentBeats(tracks: [longTrack], beatsPerBar: 4)
        // clip end 28 + one bar pad 4 = 32
        tk.expectEqual(long, 32, "long arrangement includes clip end plus one bar pad")

        // Snap Off leaves values unrounded; grid snaps.
        tk.expectEqual(ArrangementLayout.snap(1.37, to: 0.0), 1.37, "snap Off is free")
        tk.expectEqual(ArrangementLayout.snap(1.37, to: 0.25), 1.25, "1/16 snaps 1.37 → 1.25")
    }

    // MARK: - Step T1: shared BeatTimeline (arrangement + piano roll)

    tk.suite("BeatTimeline: single beats-to-x mapping for arrangement and roll") {
        tk.expectEqual(BeatTimeline.beatWidth, 28, "shared pixels-per-beat is 28")
        tk.expectEqual(BeatTimeline.x(forBeat: 0), 0, "beat 0 is at x 0")
        tk.expectEqual(BeatTimeline.x(forBeat: 8), 8 * BeatTimeline.beatWidth,
                       "beat 8 maps to 8 × beatWidth")
        tk.expectEqual(BeatTimeline.beat(atX: BeatTimeline.x(forBeat: 8)), 8,
                       "beat(atX:) inverts x(forBeat:)")
        tk.expectEqual(BeatTimeline.width(forBeats: 0.25), 0.25 * BeatTimeline.beatWidth,
                       "1/16 note width matches arrangement clip scale")

        // Note at local 0 in a clip starting at beat 8 sits under arrangement beat 8.
        let clipStart = 8.0
        let noteLocal = 0.0
        let abs = BeatTimeline.absoluteStart(clipStart: clipStart, noteLocalStart: noteLocal)
        tk.expectEqual(abs, 8, "local 0 in clip at 8 is arrangement beat 8")
        tk.expectEqual(BeatTimeline.x(forBeat: abs), BeatTimeline.x(forBeat: 8),
                       "note and arrangement event at beat 8 share the same x")
        tk.expectEqual(BeatTimeline.localBeat(absolute: 10, clipStart: 8), 2,
                       "absolute 10 in clip at 8 is local beat 2")
    }

    tk.suite("BeatTimeline: contentBeats covers arrangement and open clip notes") {
        let empty = BeatTimeline.contentBeats(tracks: [], beatsPerBar: 4, openClip: nil)
        tk.expectEqual(empty, ArrangementLayout.contentBeats(tracks: [], beatsPerBar: 4),
                       "without open clip, content matches arrangement")

        let track = Track(kind: .instrument, name: "P", instrument: .grandPiano,
                          clips: [Clip(kind: .midi, name: "c", startBeat: 4, lengthBeats: 4,
                                       midiNotes: [Note(startBeat: 0, lengthBeats: 1,
                                                        pitch: 60, velocity: 100)])])
        let open = track.clips[0]
        let withClip = BeatTimeline.contentBeats(tracks: [track], beatsPerBar: 4, openClip: open)
        let arrOnly = ArrangementLayout.contentBeats(tracks: [track], beatsPerBar: 4)
        tk.expect(withClip >= arrOnly, "open clip does not shrink content")
        tk.expect(withClip >= open.startBeat + open.lengthBeats,
                  "content covers the open clip’s end")

        // Note extending past the clip length still extends the shared axis.
        let longNote = Clip(kind: .midi, name: "long", startBeat: 0, lengthBeats: 2,
                            midiNotes: [Note(startBeat: 0, lengthBeats: 40,
                                             pitch: 60, velocity: 100)])
        let longTrack = Track(kind: .instrument, name: "P", instrument: .grandPiano,
                              clips: [longNote])
        let longContent = BeatTimeline.contentBeats(
            tracks: [longTrack], beatsPerBar: 4, openClip: longNote)
        tk.expect(longContent >= 40, "note end past clip length extends shared contentBeats")
    }

    tk.suite("AppStore T1: open roll expands inline pane; collapse keeps clip") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = Clip(kind: .midi, name: "phrase", startBeat: 8, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [clip]
        tk.expect(!store.showPianoRoll, "roll starts collapsed (no sheet)")

        store.openPianoRoll(clipID: clip.id)
        tk.expect(store.showPianoRoll, "opening a MIDI clip expands the inline roll")
        tk.expectEqual(store.pianoRollClipID, clip.id, "open clip id is stored")

        store.showPianoRoll = false
        tk.expectEqual(store.pianoRollClipID, clip.id,
                       "collapse hides the pane but keeps the selected clip")
        store.showPianoRoll = true
        tk.expectEqual(store.pianoRollClipID, clip.id, "re-expand shows the same clip")
    }
}
