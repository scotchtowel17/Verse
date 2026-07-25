import Foundation
import VerseModel
import VerseEngine
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
        tk.expectEqual(store.project.track(id: store.activeTrackID)?.name, preset.name,
                       "preset name written to track")
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
}
