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
        // Program 12 (Marimba) is not in the curated list.
        let custom = Instrument(sf2: SoundBank.generalUserGS, program: 12, bankMSB: 121, bankLSB: 0)
        store.project.tracks[idx].instrument = custom
        let track = store.project.tracks[idx]
        tk.expect(SoundBank.preset(matching: custom) == nil, "Marimba is off-list")
        tk.expectEqual(SoundBank.displayName(for: custom), "Custom (program 12)",
                       "honest custom label")
        tk.expectEqual(store.presetSelectionKey(for: track), SoundBank.selectionKey(for: custom),
                       "selection key is program+bank even when custom")
        tk.expectEqual(store.currentPresetName, "Custom (program 12)",
                       "currentPresetName uses custom label")
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
}
