import Foundation
import VerseModel
import VerseEngine
import VersePersistence
import VerseAI
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

    tk.suite("AppStore X1: track colour round-robin on add; setTrackColorIndex undoes") {
        tk.expectEqual(TrackIdentityColor.swatches.count, TrackPalette.count,
                       "UI swatches match palette size")

        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // newUntitled seed is colour 0; first added track is 1, then 2.
        tk.expectEqual(store.project.tracks[0].colorIndex, 0, "seed track colour 0")
        store.addInstrumentTrack()
        tk.expectEqual(store.project.tracks.last?.colorIndex, 1, "first add gets colour 1")
        store.addAudioTrack()
        tk.expectEqual(store.project.tracks.last?.colorIndex, 2, "second add gets colour 2")

        let tid = store.project.tracks[0].id
        store.setTrackColorIndex(5, tid)
        tk.expectEqual(store.project.track(id: tid)?.colorIndex, 5, "colour set to 5")
        tk.expectEqual(store.undoName, "Track Colour", "setTrackColorIndex labels undo")

        // Same index is a no-op (no extra undo entry).
        let depth = undoDepth(of: store)
        store.setTrackColorIndex(5, tid)
        tk.expectEqual(undoDepth(of: store), depth, "same colour does not push undo")

        store.setTrackColorIndex(99, tid)
        tk.expectEqual(store.project.track(id: tid)?.colorIndex, 99 % 8,
                       "out-of-range colour is normalized")

        store.undo()
        tk.expectEqual(store.project.track(id: tid)?.colorIndex, 5,
                       "undo restores previous colour")
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

    // MARK: - Phase P2b / P3 / T4: piano roll layout + undo grouping

    tk.suite("Piano roll layout: visiblePitchRange is pure, clamped, and fills the pane (T4)") {
        let rowH = PianoRollLayout.rowHeight
        let defaultPane = PianoRollLayout.defaultPitchPaneHeight
        let expectedRows = PianoRollLayout.defaultViewportPitchRows

        // Mid-keyboard focus: full window of whole rows, centred.
        let mid = PianoRollLayout.visiblePitchRange(
            focusPitch: 60, paneHeight: defaultPane, rowHeight: rowH)
        tk.expectEqual(mid.upperBound - mid.lowerBound + 1, expectedRows,
                       "default pane shows exactly \(expectedRows) whole rows")
        tk.expect(mid.contains(60), "focus pitch sits inside the visible range")
        tk.expect(mid.lowerBound >= 0 && mid.upperBound <= 127, "range stays in MIDI 0…127")
        // Focus should be at or next to the centre row (odd/even row count).
        let midCenter = mid.lowerBound + (expectedRows - 1) / 2
        tk.expectEqual(midCenter, 60, "focus is the centre of the window (got centre \(midCenter))")

        // Bottom clamp: window shifts up rather than shrinking.
        let bot = PianoRollLayout.visiblePitchRange(
            focusPitch: 2, paneHeight: defaultPane, rowHeight: rowH)
        tk.expectEqual(bot.lowerBound, 0, "bottom clamp pins low end at 0")
        tk.expectEqual(bot.upperBound - bot.lowerBound + 1, expectedRows,
                       "bottom clamp still fills the pane (no shrink)")
        tk.expect(bot.upperBound <= 127, "bottom-clamped range stays in MIDI")

        // Top clamp: window shifts down rather than shrinking.
        let top = PianoRollLayout.visiblePitchRange(
            focusPitch: 125, paneHeight: defaultPane, rowHeight: rowH)
        tk.expectEqual(top.upperBound, 127, "top clamp pins high end at 127")
        tk.expectEqual(top.upperBound - top.lowerBound + 1, expectedRows,
                       "top clamp still fills the pane (no shrink)")
        tk.expect(top.lowerBound >= 0, "top-clamped range stays in MIDI")

        // Huge pane: cannot exceed 0…127.
        let huge = PianoRollLayout.visiblePitchRange(
            focusPitch: 60, paneHeight: rowH * 200, rowHeight: rowH)
        tk.expectEqual(huge.lowerBound, 0, "huge pane starts at MIDI 0")
        tk.expectEqual(huge.upperBound, 127, "huge pane ends at MIDI 127")

        // Empty / zero height still yields at least one row.
        let tiny = PianoRollLayout.visiblePitchRange(
            focusPitch: 60, paneHeight: 0, rowHeight: rowH)
        tk.expectEqual(tiny.lowerBound, tiny.upperBound, "zero-height pane shows one row")
        tk.expect(tiny.contains(60), "zero-height pane still centres on focus")

        tk.expectEqual(PianoRollLayout.focusPitch(notes: []), 60, "empty clip focuses middle C")
        tk.expectEqual(PianoRollLayout.rangeLabel(60...72), "C4-C5",
                       "range label uses pitch names")
        tk.expect(PianoRollLayout.defaultBandHeight
                    >= PianoRollLayout.rowHeight * 24 + PianoRollLayout.snapToolbarHeight - 1,
                  "default band is at least ~2 octaves plus the pinned toolbar")
    }

    tk.suite("Piano roll layout: drawn row count equals range-label pitch count (X3)") {
        // Correctness: whatever pane height the grid is given, the number of rows drawn
        // must equal the number of pitches in the range the label reports. The live bug was
        // a half-height clip: label said 24 (D#4-D6) while ~12 rows were visible.
        let rowH = PianoRollLayout.rowHeight
        let focus = 75  // mean of a lead-ish cluster; range label lands near D#4-D6 at 24 rows
        for rows in [1, 6, 12, 16, 24, 36] {
            let paneH = rowH * CGFloat(rows)
            let range = PianoRollLayout.visiblePitchRange(
                focusPitch: focus, paneHeight: paneH, rowHeight: rowH)
            let drawn = PianoRollLayout.drawnRowCount(paneHeight: paneH, rowHeight: rowH)
            let labelled = range.upperBound - range.lowerBound + 1
            tk.expectEqual(drawn, rows,
                           "pane of \(rows) row-heights draws \(rows) rows (got \(drawn))")
            tk.expectEqual(labelled, drawn,
                           "range label span equals drawn rows at \(rows) (label \(labelled), drawn \(drawn), range \(PianoRollLayout.rangeLabel(range)))")
            // rangeLabel is pure formatting of the same range the grid uses.
            tk.expectEqual(
                PianoRollLayout.rangeLabel(range),
                "\(PianoRollLayout.pitchLabel(range.lowerBound))-\(PianoRollLayout.pitchLabel(range.upperBound))",
                "rangeLabel is exactly low-high of the drawn range"
            )
        }
        // Partial row of height does not invent an extra drawn row (floor, not ceil).
        let partial = rowH * 12 + rowH * 0.4
        let partialRange = PianoRollLayout.visiblePitchRange(
            focusPitch: focus, paneHeight: partial, rowHeight: rowH)
        tk.expectEqual(
            partialRange.upperBound - partialRange.lowerBound + 1,
            PianoRollLayout.drawnRowCount(paneHeight: partial, rowHeight: rowH),
            "partial-row pane: drawn count matches labelled span"
        )
        tk.expectEqual(
            PianoRollLayout.drawnRowCount(paneHeight: partial, rowHeight: rowH),
            12,
            "0.4 of a row does not add a 13th drawn row"
        )
    }

    tk.suite("Piano roll layout: fitBandHeights keeps stack inside the viewport (X3)") {
        let ruler: CGFloat = BeatTimeline.rulerHeight
        let divider: CGFloat = 8
        let minArr: CGFloat = 100
        let minRoll: CGFloat = 140
        let prefArr: CGFloat = 150
        let prefRoll = PianoRollLayout.defaultBandHeight  // ~2 octaves + snap bar

        // Plenty of room: preferred sizes win.
        let roomy = PianoRollLayout.fitBandHeights(
            availableHeight: 900,
            rulerHeight: ruler,
            dividerHeight: divider,
            rollExpanded: true,
            preferredArrangement: prefArr,
            preferredRoll: prefRoll,
            minArrangement: minArr,
            minRoll: minRoll
        )
        tk.expectEqual(roomy.arrangement, prefArr, "roomy viewport keeps preferred arrangement")
        tk.expectEqual(roomy.roll, prefRoll, "roomy viewport keeps preferred roll")

        // Tight viewport (action bar + chrome steal height): stack must fit, no clip.
        let tightBudget: CGFloat = 280
        let tight = PianoRollLayout.fitBandHeights(
            availableHeight: tightBudget,
            rulerHeight: ruler,
            dividerHeight: divider,
            rollExpanded: true,
            preferredArrangement: prefArr,
            preferredRoll: prefRoll,
            minArrangement: minArr,
            minRoll: minRoll
        )
        let tightStack = ruler + tight.arrangement + divider + tight.roll
        tk.expect(tightStack <= tightBudget + 0.5,
                  "tight stack \(tightStack) fits viewport \(tightBudget)")
        tk.expect(tight.roll > 0, "tight viewport still gives the roll some height")
        // The pitch pane inside the roll is (roll - snap bar); row count from that pane
        // must equal the labelled span (same invariant as the draw path).
        let pane = max(0, tight.roll - PianoRollLayout.snapToolbarHeight)
        let range = PianoRollLayout.visiblePitchRange(
            focusPitch: 75, paneHeight: pane, rowHeight: PianoRollLayout.rowHeight)
        let drawn = PianoRollLayout.drawnRowCount(
            paneHeight: pane, rowHeight: PianoRollLayout.rowHeight)
        tk.expectEqual(range.upperBound - range.lowerBound + 1, drawn,
                       "after fit, labelled pitch count equals drawn rows")

        // Collapsed roll: all band budget goes to arrangement.
        let collapsed = PianoRollLayout.fitBandHeights(
            availableHeight: 300,
            rulerHeight: ruler,
            dividerHeight: 0,
            rollExpanded: false,
            preferredArrangement: prefArr,
            preferredRoll: prefRoll,
            minArrangement: minArr,
            minRoll: minRoll
        )
        tk.expectEqual(collapsed.roll, 0, "collapsed roll gets zero band height")
        tk.expect(collapsed.arrangement <= 300 - ruler + 0.5,
                  "collapsed arrangement fits remaining budget")
    }

    tk.suite("Piano roll layout: visible range contains lead-cluster notes (T4)") {
        // Lead-style clip: four notes at 72–76. Opening centres on the mean, so both the
        // short pane and the default ~2-octave pane must include the whole cluster.
        let leadNotes = [72, 73, 74, 76].map {
            Note(startBeat: 0, lengthBeats: 0.5, pitch: $0, velocity: 100)
        }
        let focus = PianoRollLayout.focusPitch(notes: leadNotes)
        tk.expect(focus >= 72 && focus <= 76, "focus pitch sits inside the note cluster (got \(focus))")

        let shortPane = PianoRollLayout.rowHeight * 7
        let shortRange = PianoRollLayout.visiblePitchRange(
            focusPitch: focus, paneHeight: shortPane, rowHeight: PianoRollLayout.rowHeight)
        for p in [72, 73, 74, 76] {
            tk.expect(shortRange.contains(p), "short pane contains lead pitch \(p)")
        }
        tk.expectEqual(shortRange.upperBound - shortRange.lowerBound + 1, 7,
                       "short pane is exactly 7 whole rows")

        let defaultPane = PianoRollLayout.defaultPitchPaneHeight
        let defaultRange = PianoRollLayout.visiblePitchRange(
            focusPitch: focus, paneHeight: defaultPane, rowHeight: PianoRollLayout.rowHeight)
        for p in [72, 73, 74, 76] {
            tk.expect(defaultRange.contains(p), "default pane contains lead pitch \(p)")
        }
        // Hit-testing uses the same range: y of focus maps back to focus.
        let y = PianoRollLayout.yForPitch(focus, pitchHigh: defaultRange.upperBound,
                                          rowHeight: PianoRollLayout.rowHeight)
        let hit = PianoRollLayout.pitchAt(
            y: y + PianoRollLayout.rowHeight / 2,
            pitchLow: defaultRange.lowerBound,
            pitchHigh: defaultRange.upperBound,
            rowHeight: PianoRollLayout.rowHeight
        )
        tk.expectEqual(hit, focus, "pitchAt on focus row centre returns focus (hit-test match)")
    }

    tk.suite("Piano roll layout: bass notes visible after expand (T4, no scroll)") {
        // Live failure case across T2/T3: Bass B at 36 and 41. With a bounded window there
        // is no scroll offset to go stale; expand simply recomputes the range from height.
        let bassNotes = [36, 41].map {
            Note(startBeat: 0, lengthBeats: 0.5, pitch: $0, velocity: 100)
        }
        let focus = PianoRollLayout.focusPitch(notes: bassNotes)
        tk.expect(focus >= 36 && focus <= 41, "focus is the mean of the bass cluster (got \(focus))")

        // Tiny height (collapsed / first layout pass): still contains focus.
        let collapsed = PianoRollLayout.visiblePitchRange(
            focusPitch: focus,
            paneHeight: PianoRollLayout.rowHeight,
            rowHeight: PianoRollLayout.rowHeight
        )
        tk.expect(collapsed.contains(focus), "one-row pane still shows focus pitch")

        // Expanded default band: both bass notes must be in the drawn range.
        let expanded = PianoRollLayout.visiblePitchRange(
            focusPitch: focus,
            paneHeight: PianoRollLayout.defaultPitchPaneHeight,
            rowHeight: PianoRollLayout.rowHeight
        )
        tk.expect(expanded.contains(36) && expanded.contains(41),
                  "expanded pane contains both bass notes 36 and 41 (got \(expanded))")
        tk.expectEqual(
            expanded.upperBound - expanded.lowerBound + 1,
            PianoRollLayout.defaultViewportPitchRows,
            "expanded pane fills with whole rows"
        )
        // Resize to a different height recomputes without any scroll state.
        let resized = PianoRollLayout.visiblePitchRange(
            focusPitch: focus,
            paneHeight: PianoRollLayout.rowHeight * 16,
            rowHeight: PianoRollLayout.rowHeight
        )
        tk.expect(resized.contains(36) && resized.contains(41),
                  "resized pane still contains both bass notes")
        tk.expectEqual(resized.upperBound - resized.lowerBound + 1, 16,
                       "resized pane is exactly 16 rows")
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

    tk.suite("AppStore W1: brand-new track opens roll without creating a clip") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Default project: one instrument track, no clips. Roll is track-bound, clip on demand.
        let track = store.project.tracks[0]
        tk.expectEqual(track.kind, TrackKind.instrument, "default track is instrument")
        tk.expectEqual(track.clips.count, 0, "brand-new project has no clips")
        tk.expect(store.showPianoRoll, "roll starts expanded on a fresh launch")

        store.openPianoRoll(forTrack: track.id)
        tk.expect(store.showPianoRoll, "piano roll stays open for empty track")
        tk.expectEqual(store.rollTrackID, track.id, "roll binds to the track")
        tk.expect(store.pianoRollClipID == nil, "no explicit clip until the user draws")
        tk.expect(store.effectivePianoRollClipID == nil, "nothing to auto-resolve yet")
        tk.expectEqual(store.project.tracks[0].clips.count, 0, "opening does not create a clip")
        tk.expectEqual(undoDepth(of: store), 0, "open-without-draw records no undo")
    }

    tk.suite("AppStore W1: first note creates clip + note as one Add Note undo") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let track = store.project.tracks[0]
        store.openPianoRoll(forTrack: track.id)
        tk.expectEqual(track.clips.count, 0, "still empty before draw")

        // Arrangement-absolute start (empty roll treats clip start as 0).
        let noteID = store.pianoRollAddNote(pitch: 60, startBeat: 2.0, lengthBeats: 0.25)
        tk.expect(noteID != nil, "draw succeeds with no prior clip")
        tk.expectEqual(store.project.tracks[0].clips.count, 1, "one MIDI clip created on demand")
        let clip = store.project.tracks[0].clips[0]
        tk.expectEqual(clip.kind, ClipKind.midi, "created clip is MIDI")
        tk.expectEqual(clip.midiNotes?.count, 1, "note lands in the new clip")
        tk.expectEqual(clip.midiNotes?[0].id, noteID, "returned id matches")
        tk.expectEqual(store.pianoRollClipID, clip.id, "explicit clip set after create")
        tk.expectEqual(store.effectivePianoRollClipID, clip.id, "effective points at new clip")
        tk.expectEqual(undoDepth(of: store), 1, "clip+note is exactly one undo entry")
        tk.expectEqual(store.undoName, "Add Note", "combined gesture labeled Add Note")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips.count, 0, "one undo removes clip and note")
        tk.expectEqual(undoDepth(of: store), 0, "stack empty after undo")
    }

    tk.suite("AppStore piano roll: forTrack reuses existing MIDI clip, no duplicate") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 8,
                            midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [existing]
        store.openPianoRoll(forTrack: store.project.tracks[0].id)
        tk.expectEqual(store.project.tracks[0].clips.count, 1, "no second clip created")
        tk.expectEqual(store.effectivePianoRollClipID, existing.id, "auto-resolves the existing clip")
        tk.expectEqual(undoDepth(of: store), 0, "reuse path does not push undo")
    }

    tk.suite("AppStore W1: audio track shows roll without MIDI clip") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.addAudioTrack()
        let audioID = store.project.tracks.last!.id
        let clipsBefore = store.project.tracks.last!.clips.count
        store.openPianoRoll(forTrack: audioID)
        tk.expect(store.showPianoRoll, "audio track still expands the roll pane")
        tk.expectEqual(store.rollTrackID, audioID, "roll binds to the audio track")
        tk.expect(store.pianoRollIsAudioTrack, "audio empty-state flag is set")
        tk.expect(store.effectivePianoRollClipID == nil, "no MIDI clip on audio track")
        tk.expectEqual(store.project.tracks.last!.clips.count, clipsBefore,
                       "audio track is not given a MIDI clip")
        let noteID = store.pianoRollAddNote(pitch: 60, startBeat: 0, lengthBeats: 0.25)
        tk.expect(noteID == nil, "drawing on audio refuses")
        tk.expectEqual(store.project.tracks.last!.clips.count, clipsBefore,
                       "refused draw creates no clip")
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

    // MARK: - Step U1: clip selection helpers, multi-move, paste, delete

    tk.suite("Arrangement U1: marquee selects clips it touches") {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let clips: [(id: UUID, startBeat: Double, lengthBeats: Double, trackIndex: Int)] = [
            (id: a, startBeat: 0, lengthBeats: 2, trackIndex: 0),
            (id: b, startBeat: 4, lengthBeats: 2, trackIndex: 0),
            (id: c, startBeat: 0, lengthBeats: 2, trackIndex: 1),
        ]
        // Beats 0–3 on track 0 only: hits a, not b or c.
        let hit = ArrangementSelection.clipsTouchingMarquee(
            clips: clips, beatA: 0, beatB: 3, trackA: 0, trackB: 0)
        tk.expectEqual(Set(hit), Set([a]), "marquee on track 0 early beats hits only a")

        // Vertical marquee covering both tracks at beat 0–1: hits a and c.
        let both = ArrangementSelection.clipsTouchingMarquee(
            clips: clips, beatA: 0, beatB: 1, trackA: 0, trackB: 1)
        tk.expectEqual(Set(both), Set([a, c]), "vertical marquee hits both tracks")

        // Edge: marquee starting exactly at clip end does not touch.
        let edge = ArrangementSelection.clipTouchesMarquee(
            startBeat: 0, lengthBeats: 2, trackIndex: 0,
            beatA: 2, beatB: 4, trackA: 0, trackB: 0)
        tk.expect(!edge, "marquee at clip end does not touch")
    }

    tk.suite("Arrangement U1: group move preserves formation or rejects whole") {
        let origins: [(startBeat: Double, trackIndex: Int)] = [
            (startBeat: 1, trackIndex: 0),
            (startBeat: 3, trackIndex: 1),
        ]
        let ok = ArrangementSelection.applyGroupDelta(
            origins: origins, beatDelta: 2, trackDelta: 0, trackCount: 3)
        tk.expect(ok != nil, "in-range group time move accepted")
        tk.expectEqual(ok![0].startBeat, 3, "primary time shifted")
        tk.expectEqual(ok![1].startBeat, 5, "relative time preserved")

        let up = ArrangementSelection.applyGroupDelta(
            origins: origins, beatDelta: 0, trackDelta: 1, trackCount: 3)
        tk.expect(up != nil, "in-range track delta accepted")
        tk.expectEqual(up![0].trackIndex, 1, "track 0 → 1")
        tk.expectEqual(up![1].trackIndex, 2, "track 1 → 2")

        let beforeZero = ArrangementSelection.applyGroupDelta(
            origins: origins, beatDelta: -2, trackDelta: 0, trackCount: 3)
        tk.expect(beforeZero == nil, "start before 0 rejects whole selection")

        let offTracks = ArrangementSelection.applyGroupDelta(
            origins: origins, beatDelta: 0, trackDelta: 2, trackCount: 3)
        tk.expect(offTracks == nil, "track out of range rejects whole selection")
    }

    tk.suite("Arrangement U1: paste offsets preserve relative starts at playhead") {
        let starts = [2.0, 2.5, 5.0]
        let pasted = ArrangementSelection.pasteStartBeats(
            clipboardStarts: starts, playheadBeat: 8.0)
        tk.expectEqual(pasted, [8.0, 8.5, 11.0],
                       "earliest maps to playhead; others keep offsets")
        let empty = ArrangementSelection.pasteStartBeats(
            clipboardStarts: [], playheadBeat: 3)
        tk.expectEqual(empty.count, 0, "empty clipboard yields empty paste starts")
    }

    tk.suite("Arrangement U1: placementsCompatible enforces kind rules") {
        let kinds: [TrackKind] = [.instrument, .audio, .instrument]
        tk.expect(
            ArrangementSelection.placementsCompatible(
                clipKinds: [.midi, .midi],
                trackKinds: kinds,
                trackIndices: [0, 2]),
            "MIDI on two instrument tracks ok")
        tk.expect(
            !ArrangementSelection.placementsCompatible(
                clipKinds: [.midi],
                trackKinds: kinds,
                trackIndices: [1]),
            "MIDI on audio track rejected")
        tk.expect(
            !ArrangementSelection.placementsCompatible(
                clipKinds: [.audio],
                trackKinds: kinds,
                trackIndices: [0]),
            "audio on instrument track rejected")
        tk.expect(
            ArrangementSelection.placementsCompatible(
                clipKinds: [.audio],
                trackKinds: kinds,
                trackIndices: [1]),
            "audio on audio track ok")
    }

    tk.suite("AppStore U1: multi-delete is one undo entry") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let c1 = Clip(kind: .midi, name: "a", startBeat: 0, lengthBeats: 2, midiNotes: [])
        let c2 = Clip(kind: .midi, name: "b", startBeat: 4, lengthBeats: 2, midiNotes: [])
        let c3 = Clip(kind: .midi, name: "c", startBeat: 8, lengthBeats: 2, midiNotes: [])
        store.project.tracks[0].clips = [c1, c2, c3]
        store.openPianoRoll(clipID: c1.id)

        store.arrangementDeleteClips(ids: [c1.id, c2.id])
        tk.expectEqual(store.project.tracks[0].clips.count, 1, "two clips deleted, one remains")
        tk.expectEqual(store.project.tracks[0].clips[0].id, c3.id, "remaining is the untouched one")
        tk.expectEqual(undoDepth(of: store), 1, "multi-delete is exactly one undo entry")
        tk.expectEqual(store.undoName, "Delete Clips", "multi-delete label")
        tk.expect(store.pianoRollClipID == nil, "open roll cleared when its clip was deleted")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips.count, 3, "one undo restores both deleted clips")
    }

    tk.suite("AppStore U1: group move is one undo; kind mismatch refuses whole") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.addAudioTrack()
        store.addInstrumentTrack()
        // tracks: [0 instrument Piano, 1 audio, 2 instrument]
        let midiA = Clip(kind: .midi, name: "a", startBeat: 0, lengthBeats: 2,
                         midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        let midiB = Clip(kind: .midi, name: "b", startBeat: 2, lengthBeats: 2,
                         midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 64, velocity: 100)])
        store.project.tracks[0].clips = [midiA, midiB]
        let depthAfterTracks = undoDepth(of: store)

        store.beginArrangementGesture(name: "Move Clips")
        for _ in 1...8 {
            store.arrangementMoveClips([
                (id: midiA.id, startBeat: 1, trackIndex: 0),
                (id: midiB.id, startBeat: 3, trackIndex: 0),
            ])
        }
        // Kind mismatch: MIDI onto audio track. Whole update rejected.
        store.arrangementMoveClips([
            (id: midiA.id, startBeat: 1, trackIndex: 1),
            (id: midiB.id, startBeat: 3, trackIndex: 1),
        ])
        store.endArrangementGesture()

        tk.expectEqual(store.project.tracks[0].clips.count, 2, "MIDI still on instrument after refuse")
        tk.expectEqual(store.project.tracks[1].clips.count, 0, "audio track did not receive MIDI")
        let aAfter = store.project.tracks[0].clips.first { $0.id == midiA.id }!
        let bAfter = store.project.tracks[0].clips.first { $0.id == midiB.id }!
        tk.expectEqual(aAfter.startBeat, 1, "kept last valid start for A")
        tk.expectEqual(bAfter.startBeat, 3, "kept last valid start for B")
        // Capture before undoDepth: that helper undoes/redoes and rewrites statusMessage.
        let refuseStatus = store.statusMessage
        tk.expect(refuseStatus != nil, "kind refusal sets a clear status message")
        tk.expect(refuseStatus!.contains("MIDI") || refuseStatus!.contains("audio"),
                  "status names the kind problem")
        tk.expectEqual(store.undoName, "Move Clips", "group move label")
        tk.expectEqual(undoDepth(of: store), depthAfterTracks + 1,
                       "many group updates are one undo entry")

        let depthAfterFirstMove = undoDepth(of: store)
        // Valid cross-track move onto the other instrument track.
        store.beginArrangementGesture(name: "Move Clips")
        store.arrangementMoveClips([
            (id: midiA.id, startBeat: 4, trackIndex: 2),
            (id: midiB.id, startBeat: 6, trackIndex: 2),
        ])
        store.endArrangementGesture()
        tk.expectEqual(store.project.tracks[0].clips.count, 0, "source emptied")
        tk.expectEqual(store.project.tracks[2].clips.count, 2, "both on Lead instrument")
        tk.expectEqual(undoDepth(of: store), depthAfterFirstMove + 1,
                       "second gesture is a second undo entry")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips.count, 2, "undo restores prior track placement")
    }

    tk.suite("AppStore U1: paste at playhead is one undo; deep-copies UUIDs") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let n1 = Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 1, lengthBeats: 1, pitch: 64, velocity: 90)
        let src = Clip(kind: .midi, name: "phrase", startBeat: 2, lengthBeats: 4,
                       midiNotes: [n1, n2])
        store.project.tracks[0].clips = [src]
        store.scrubPlayhead(to: 10.0)

        let starts = ArrangementSelection.pasteStartBeats(
            clipboardStarts: [2.0], playheadBeat: 10.0)
        tk.expectEqual(starts, [10.0], "playhead anchors the earliest clip")

        let ids = store.arrangementPasteClips([
            (clip: src, startBeat: starts[0], trackIndex: 0),
        ])
        tk.expectEqual(ids.count, 1, "paste returns one new id")
        tk.expectEqual(store.project.tracks[0].clips.count, 2, "original + paste")
        tk.expect(ids[0] != src.id, "pasted clip has a fresh UUID")
        let pasted = store.project.tracks[0].clips.first { $0.id == ids[0] }!
        tk.expectEqual(pasted.startBeat, 10.0, "paste at playhead")
        tk.expectEqual(pasted.midiNotes?.count, 2, "notes pasted")
        let origNoteIDs = Set([n1.id, n2.id])
        let pasteNoteIDs = Set((pasted.midiNotes ?? []).map(\.id))
        tk.expect(origNoteIDs.isDisjoint(with: pasteNoteIDs), "note UUIDs regenerated via deepCopy")
        tk.expectEqual(undoDepth(of: store), 1, "paste is exactly one undo entry")
        tk.expectEqual(store.undoName, "Paste Clips", "paste undo label")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips.count, 1, "one undo removes the whole paste")
    }

    tk.suite("AppStore U1: paste kind mismatch refuses; cut is one undo") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.addAudioTrack()
        let midi = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 2, midiNotes: [])
        store.project.tracks[0].clips = [midi]
        let depthAfterTracks = undoDepth(of: store)

        let refused = store.arrangementPasteClips([
            (clip: midi, startBeat: 4, trackIndex: 1), // audio track
        ])
        tk.expectEqual(refused.count, 0, "MIDI paste onto audio returns no ids")
        tk.expectEqual(store.project.tracks[1].clips.count, 0, "audio track unchanged")
        tk.expectEqual(undoDepth(of: store), depthAfterTracks,
                       "refused paste records no undo")
        tk.expect(store.statusMessage != nil, "refused paste sets status")

        let depthBeforeCut = undoDepth(of: store)
        store.arrangementDeleteClips(ids: [midi.id], undoName: "Cut Clips")
        tk.expectEqual(store.undoName, "Cut Clips", "cut uses Cut Clips label")
        tk.expectEqual(undoDepth(of: store), depthBeforeCut + 1, "cut is one undo entry")
        tk.expectEqual(store.project.tracks[0].clips.count, 0, "clip removed by cut")
    }

    tk.suite("AppStore U2: split clip is one undo; audio and edges refused") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let crossing = Note(startBeat: 1, lengthBeats: 2, pitch: 60, velocity: 100)
        let midi = Clip(kind: .midi, name: "phrase", startBeat: 0, lengthBeats: 4,
                        midiNotes: [crossing])
        store.project.tracks[0].clips = [midi]
        store.openPianoRoll(clipID: midi.id)

        let pair = store.arrangementSplitClip(id: midi.id, atArrangementBeat: 2)
        tk.expect(pair != nil, "MIDI split returns new ids")
        tk.expectEqual(store.project.tracks[0].clips.count, 2, "two halves after split")
        tk.expectEqual(store.undoName, "Split Clip", "split undo label")
        tk.expectEqual(undoDepth(of: store), 1, "split is exactly one undo entry")
        tk.expectEqual(store.pianoRollClipID, pair!.left, "open roll retargets to left half")
        print("DEBUG after retarget assert: pianoRollClipID=\(String(describing: store.pianoRollClipID))")
        let left = store.project.tracks[0].clips[0]
        let right = store.project.tracks[0].clips[1]
        tk.expectEqual(left.lengthBeats, 2, "left half length")
        tk.expectEqual(right.startBeat, 2, "right half start")
        tk.expectEqual(left.midiNotes?.count, 1, "left has first part of crossing")
        tk.expectEqual(right.midiNotes?.count, 1, "right has second part of crossing")
        tk.expectEqual(
            (left.midiNotes![0].lengthBeats) + (right.midiNotes![0].lengthBeats),
            2,
            "crossing parts sum to original")

        store.undo()
        tk.expectEqual(store.project.tracks[0].clips.count, 1, "one undo restores original")
        tk.expectEqual(store.project.tracks[0].clips[0].id, midi.id, "original clip id restored")
        tk.expectEqual(store.project.tracks[0].clips[0].midiNotes?.count, 1,
                       "original notes restored")

        // Edge refuse: no undo, clear message.
        store.statusMessage = nil
        let atStart = store.arrangementSplitClip(id: midi.id, atArrangementBeat: 0)
        tk.expect(atStart == nil, "split at start returns nil")
        tk.expectEqual(store.project.tracks[0].clips.count, 1, "edge refuse leaves one clip")
        tk.expect(store.statusMessage != nil, "edge refuse sets status")
        tk.expectEqual(undoDepth(of: store), 0, "refused split records no undo after undo")

        // Audio refuse.
        store.addAudioTrack()
        let audio = Clip(kind: .audio, name: "take", startBeat: 0, lengthBeats: 4,
                         mediaFile: "t.wav")
        store.project.tracks[1].clips = [audio]
        store.statusMessage = nil
        let audioSplit = store.arrangementSplitClip(id: audio.id, atArrangementBeat: 2)
        tk.expect(audioSplit == nil, "audio split returns nil")
        tk.expectEqual(store.project.tracks[1].clips.count, 1, "audio clip still there")
        let audioStatus = store.statusMessage
        tk.expect(audioStatus != nil, "audio refuse sets status")
        tk.expect(
            audioStatus!.localizedCaseInsensitiveContains("audio"),
            "audio refuse message names audio")
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
        tk.expectEqual(BeatTimeline.baseBeatWidth, 28, "base pixels-per-beat is 28")
        tk.expectEqual(BeatTimeline.beatWidth, 28, "default zoom yields 28 px/beat")
        tk.expectEqual(BeatTimeline.beatWidth(zoom: 1.0), 28, "zoom 1.0 is base width")
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

    // MARK: - Step X2: zoom, quantize UI, action bar enablement

    tk.suite("X2 BeatTimeline zoom scales shared beat↔x mapping") {
        let z2 = 2.0
        tk.expectEqual(BeatTimeline.beatWidth(zoom: z2), BeatTimeline.baseBeatWidth * 2,
                       "zoom 2 doubles pixels per beat")
        tk.expectEqual(BeatTimeline.x(forBeat: 4, zoom: z2),
                       BeatTimeline.x(forBeat: 4, zoom: 1) * 2,
                       "x at zoom 2 is twice x at zoom 1 for the same beat")
        tk.expectEqual(BeatTimeline.beat(atX: BeatTimeline.x(forBeat: 7.5, zoom: z2), zoom: z2),
                       7.5, "round-trip at zoom 2")
        // Arrangement and roll must share the same zoomed x for the same beat.
        let arrX = BeatTimeline.x(forBeat: 8, zoom: 1.25)
        let rollX = BeatTimeline.x(forBeat: 8, zoom: 1.25)
        tk.expectEqual(arrX, rollX, "same zoom → same x in both panes")
        tk.expectEqual(BeatTimeline.clampedZoom(0.01), BeatTimeline.minZoom, "clamps below min")
        tk.expectEqual(BeatTimeline.clampedZoom(100), BeatTimeline.maxZoom, "clamps above max")
        tk.expectEqual(BeatTimeline.zoomedIn(from: BeatTimeline.maxZoom), BeatTimeline.maxZoom,
                       "zoom in at max stays max")
        tk.expectEqual(BeatTimeline.zoomedOut(from: BeatTimeline.minZoom), BeatTimeline.minZoom,
                       "zoom out at min stays min")
        let fit = BeatTimeline.fitZoom(contentBeats: 10, availableWidth: 280)
        // 280 / (10 * 28) = 1.0
        tk.expectEqual(fit, 1.0, "fit of 10 beats into 280 px is zoom 1")
        let fitWide = BeatTimeline.fitZoom(contentBeats: 10, availableWidth: 560)
        tk.expectEqual(fitWide, 2.0, "fit of 10 beats into 560 px is zoom 2")
    }

    tk.suite("X2 AppStore timeline zoom") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        tk.expectEqual(store.timelineZoom, BeatTimeline.defaultZoom, "starts at default zoom")
        store.zoomTimelineIn()
        tk.expect(store.timelineZoom > BeatTimeline.defaultZoom, "zoom in increases zoom")
        let afterIn = store.timelineZoom
        store.zoomTimelineOut()
        tk.expect(store.timelineZoom < afterIn, "zoom out decreases zoom")
        store.setTimelineZoom(0.01)
        tk.expectEqual(store.timelineZoom, BeatTimeline.minZoom, "setTimelineZoom clamps low")
        store.setTimelineZoom(99)
        tk.expectEqual(store.timelineZoom, BeatTimeline.maxZoom, "setTimelineZoom clamps high")
        store.zoomTimelineToFit(contentBeats: 10, availableWidth: 280)
        tk.expectEqual(store.timelineZoom, 1.0, "fit sets zoom from content width")
    }

    tk.suite("X2 AppStore quantize notes (UI path)") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let n1 = Note(startBeat: 0.1, lengthBeats: 0.25, pitch: 60, velocity: 100)
        let n2 = Note(startBeat: 0.6, lengthBeats: 0.25, pitch: 64, velocity: 100)
        let clip = Clip(kind: .midi, name: "q", startBeat: 0, lengthBeats: 4,
                        midiNotes: [n1, n2])
        store.project.tracks[0].clips = [clip]
        store.openPianoRoll(clipID: clip.id)
        store.pianoRollSnapBeats = 0.25
        store.selectedNoteIDs = []

        store.pianoRollQuantizeNotes()
        tk.expectEqual(store.undoName, "Quantize Notes", "one undo entry named Quantize Notes")
        let notes = store.project.tracks[0].clips[0].midiNotes ?? []
        tk.expectEqual(notes.count, 2, "still two notes")
        // 0.1 → 0.0, 0.6 → 0.5 on 1/16 grid
        tk.expectEqual(notes[0].startBeat, 0.0, "first note quantized to 0")
        tk.expectEqual(notes[1].startBeat, 0.5, "second note quantized to 0.5")

        // Selected-only quantize: leave one unaligned, quantize the other.
        store.project.tracks[0].clips[0].midiNotes = [
            Note(id: n1.id, startBeat: 0.13, lengthBeats: 0.25, pitch: 60, velocity: 100),
            Note(id: n2.id, startBeat: 0.63, lengthBeats: 0.25, pitch: 64, velocity: 100)
        ]
        store.selectedNoteIDs = [n1.id]
        store.pianoRollQuantizeNotes()
        let after = store.project.tracks[0].clips[0].midiNotes ?? []
        let q1 = after.first { $0.id == n1.id }?.startBeat
        let q2 = after.first { $0.id == n2.id }?.startBeat
        tk.expectEqual(q1, 0.25, "selected note 0.13 → 0.25 on 1/16")
        tk.expectEqual(q2, 0.63, "unselected note left unaligned")

        // Snap Off refuses with a clear message (no silent no-op success).
        let depthBefore = undoDepth(of: store)
        store.pianoRollSnapBeats = 0
        store.statusMessage = nil
        store.pianoRollQuantizeNotes()
        tk.expect(store.statusMessage?.localizedCaseInsensitiveContains("snap") == true,
                  "snap Off explains why quantize cannot run")
        tk.expectEqual(undoDepth(of: store), depthBefore, "refused quantize records no undo")
    }

    tk.suite("X2 AppStore duplicate clips") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = Clip(kind: .midi, name: "src", startBeat: 0, lengthBeats: 2,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [clip]
        let newIDs = store.arrangementDuplicateClips(ids: [clip.id])
        tk.expectEqual(newIDs.count, 1, "one new clip")
        tk.expectEqual(store.project.tracks[0].clips.count, 2, "two clips after duplicate")
        tk.expectEqual(store.undoName, "Duplicate Clip", "undo name for single duplicate")
        let copy = store.project.tracks[0].clips.first { $0.id == newIDs[0] }
        tk.expectEqual(copy?.startBeat, 2.0, "copy starts at original end")
        tk.expect(copy?.id != clip.id, "copy has a fresh id")
    }

    tk.suite("X2 ActionBarLogic enablement and tooltips") {
        var p = Project.newUntitled()
        let midi = Clip(kind: .midi, name: "m", startBeat: 0, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0.1, lengthBeats: 0.5, pitch: 60, velocity: 100)])
        p.tracks[0].clips = [midi]

        let undoOff = ActionBarLogic.undoHelp(canUndo: false, name: nil)
        tk.expect(!undoOff.enabled, "undo disabled when empty")
        tk.expect(undoOff.help.localizedCaseInsensitiveContains("nothing"), "undo tooltip explains")
        let undoOn = ActionBarLogic.undoHelp(canUndo: true, name: "Add Note")
        tk.expect(undoOn.enabled, "undo enabled when stack has entry")
        tk.expect(undoOn.help.contains("Add Note"), "undo tooltip names the action")

        let splitEmpty = ActionBarLogic.splitHelp(selectedClipIDs: [], project: p, playheadBeat: 2)
        tk.expect(!splitEmpty.enabled, "split disabled with no selection")
        let splitOK = ActionBarLogic.splitHelp(
            selectedClipIDs: [midi.id], project: p, playheadBeat: 2)
        tk.expect(splitOK.enabled, "split enabled for MIDI with playhead inside")
        let splitEdge = ActionBarLogic.splitHelp(
            selectedClipIDs: [midi.id], project: p, playheadBeat: 0)
        tk.expect(!splitEdge.enabled, "split disabled at clip start")
        tk.expect(splitEdge.help.localizedCaseInsensitiveContains("playhead"),
                  "split edge tooltip mentions playhead")

        let dup = ActionBarLogic.duplicateHelp(selectedClipIDs: [midi.id])
        tk.expect(dup.enabled, "duplicate enabled with selection")
        let dupEmpty = ActionBarLogic.duplicateHelp(selectedClipIDs: [])
        tk.expect(!dupEmpty.enabled, "duplicate disabled without selection")

        let delNotes = ActionBarLogic.deleteHelp(
            surface: .pianoRoll, selectedClipIDs: [], selectedNoteIDs: [UUID()])
        tk.expect(delNotes.enabled, "delete notes when roll focused")
        let delClips = ActionBarLogic.deleteHelp(
            surface: .arrangement, selectedClipIDs: [midi.id], selectedNoteIDs: [])
        tk.expect(delClips.enabled, "delete clips when arrangement focused")
        let delNone = ActionBarLogic.deleteHelp(
            surface: .arrangement, selectedClipIDs: [], selectedNoteIDs: [UUID()])
        tk.expect(!delNone.enabled, "delete disabled when arrangement has no clip selection")

        let qAll = ActionBarLogic.quantizeHelp(
            snapBeats: 0.25, openClip: midi, isAudioTrack: false, selectedNoteIDs: [])
        tk.expect(qAll.enabled, "quantize whole clip when snap on")
        let qOff = ActionBarLogic.quantizeHelp(
            snapBeats: 0, openClip: midi, isAudioTrack: false, selectedNoteIDs: [])
        tk.expect(!qOff.enabled, "quantize disabled when snap off")
        tk.expect(qOff.help.localizedCaseInsensitiveContains("snap"), "quantize off explains snap")
        let qAudio = ActionBarLogic.quantizeHelp(
            snapBeats: 0.25, openClip: nil, isAudioTrack: true, selectedNoteIDs: [])
        tk.expect(!qAudio.enabled, "quantize disabled on audio track")

        let zIn = ActionBarLogic.zoomInHelp(zoom: BeatTimeline.maxZoom)
        tk.expect(!zIn.enabled, "zoom in disabled at max")
        let zOut = ActionBarLogic.zoomOutHelp(zoom: BeatTimeline.minZoom)
        tk.expect(!zOut.enabled, "zoom out disabled at min")
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

    tk.suite("AppStore T1/W1: roll starts expanded; collapse keeps clip") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clip = Clip(kind: .midi, name: "phrase", startBeat: 8, lengthBeats: 4,
                        midiNotes: [Note(startBeat: 0, lengthBeats: 1, pitch: 60, velocity: 100)])
        store.project.tracks[0].clips = [clip]
        tk.expect(store.showPianoRoll, "roll starts expanded on a fresh launch")

        store.openPianoRoll(clipID: clip.id)
        tk.expect(store.showPianoRoll, "opening a MIDI clip keeps the inline roll expanded")
        tk.expectEqual(store.pianoRollClipID, clip.id, "open clip id is stored")
        tk.expectEqual(store.effectivePianoRollClipID, clip.id, "effective matches explicit")

        store.showPianoRoll = false
        tk.expectEqual(store.pianoRollClipID, clip.id,
                       "collapse hides the pane but keeps the selected clip")
        store.showPianoRoll = true
        tk.expectEqual(store.pianoRollClipID, clip.id, "re-expand shows the same clip")
    }

    tk.suite("AppStore W1: multi-clip resolve prefers playhead, then earlier, then first") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let c1 = Clip(kind: .midi, name: "a", startBeat: 0, lengthBeats: 4, midiNotes: [])
        let c2 = Clip(kind: .midi, name: "b", startBeat: 8, lengthBeats: 4, midiNotes: [])
        let c3 = Clip(kind: .midi, name: "c", startBeat: 16, lengthBeats: 4, midiNotes: [])
        store.project.tracks[0].clips = [c1, c2, c3]
        store.rollTrackID = store.project.tracks[0].id
        store.pianoRollClipID = nil

        store.playheadBeat = 9
        tk.expectEqual(store.effectivePianoRollClipID, c2.id, "clip under playhead wins")

        store.playheadBeat = 6
        tk.expectEqual(store.effectivePianoRollClipID, c1.id, "nearest earlier when between clips")

        store.playheadBeat = 0
        tk.expectEqual(store.effectivePianoRollClipID, c1.id, "first clip when playhead is at start")

        // Explicit arrangement selection wins over auto-resolve.
        store.openPianoRoll(clipID: c3.id)
        store.playheadBeat = 9
        tk.expectEqual(store.effectivePianoRollClipID, c3.id, "explicit clip beats playhead")

        // forTrack clears explicit and re-resolves from playhead.
        store.openPianoRoll(forTrack: store.project.tracks[0].id)
        tk.expect(store.pianoRollClipID == nil, "forTrack clears explicit override")
        store.playheadBeat = 9
        tk.expectEqual(store.effectivePianoRollClipID, c2.id, "auto-resolve after forTrack")
    }

    tk.suite("AppStore W1: pure helpers for resolve and on-demand placement") {
        let early = Clip(kind: .midi, name: "e", startBeat: 0, lengthBeats: 4, midiNotes: [])
        let mid = Clip(kind: .midi, name: "m", startBeat: 8, lengthBeats: 4, midiNotes: [])
        let late = Clip(kind: .midi, name: "l", startBeat: 16, lengthBeats: 4, midiNotes: [])
        let clips = [early, mid, late]

        tk.expectEqual(
            PianoRollSelection.resolvedMIDIClip(clips: clips, playheadBeat: 10)?.id,
            mid.id, "resolve under playhead")
        tk.expectEqual(
            PianoRollSelection.resolvedMIDIClip(clips: clips, playheadBeat: 5)?.id,
            early.id, "resolve nearest earlier")
        tk.expectEqual(
            PianoRollSelection.resolvedMIDIClip(clips: clips, playheadBeat: 100)?.id,
            late.id, "resolve latest earlier when past all")
        tk.expect(
            PianoRollSelection.resolvedMIDIClip(clips: [], playheadBeat: 0) == nil,
            "empty list resolves to nil")

        let place = PianoRollSelection.onDemandClipPlacement(
            absoluteNoteStart: 8.5, noteLengthBeats: 0.25, beatsPerBar: 4)
        tk.expectEqual(place.clipStart, 8.0, "clip starts on bar containing the note")
        tk.expectEqual(place.localNoteStart, 0.5, "note is clip-local")
        tk.expect(place.clipLength >= 16.0, "at least 4 bars long")
        tk.expect(place.clipLength >= place.localNoteStart + 0.25, "length covers the note")
    }

    // MARK: - Step V4: silent no-op audit (swallows must surface status)

    tk.suite("AppStore V4: delete last track refuses with status, no undo") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        tk.expectEqual(store.project.tracks.count, 1, "fresh project has one track")
        let onlyID = store.project.tracks[0].id
        store.statusMessage = nil
        store.deleteTrack(onlyID)
        tk.expectEqual(store.project.tracks.count, 1, "last track still present")
        tk.expectEqual(store.project.tracks[0].id, onlyID, "same track id kept")
        tk.expect(!store.canUndo, "refused delete records no undo")
        let msg = store.statusMessage
        tk.expect(msg != nil, "last-track refuse sets status")
        tk.expect(
            msg!.localizedCaseInsensitiveContains("at least one")
                || msg!.localizedCaseInsensitiveContains("one track"),
            "status names the one-track rule")
    }

    tk.suite("AppStore V4: delete missing track refuses with status, no empty undo") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.addInstrumentTrack()
        tk.expect(store.project.tracks.count > 1, "more than one track so count guard passes")
        let depth = undoDepth(of: store)
        store.statusMessage = nil
        store.deleteTrack(UUID())
        // Capture before undoDepth: that helper undoes/redoes and rewrites statusMessage.
        let missingMsg = store.statusMessage
        tk.expectEqual(store.project.tracks.count, 2, "no track removed for unknown id")
        tk.expectEqual(undoDepth(of: store), depth, "missing-track refuse records no undo")
        tk.expect(missingMsg != nil, "missing track sets status")
        // Match substance, not a specific apostrophe glyph (curly vs ASCII).
        tk.expect(
            (missingMsg ?? "").localizedCaseInsensitiveContains("track")
                && (missingMsg ?? "").localizedCaseInsensitiveContains("project"),
            "status names the missing track (got: \(missingMsg ?? "nil"))")
    }

    tk.suite("AppStore V4: selectPreset on missing track sets status") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        guard let preset = SoundBank.presets.first else {
            tk.expect(false, "SoundBank has at least one preset")
            return
        }
        store.statusMessage = nil
        store.selectPreset(preset, for: UUID())
        tk.expect(!store.canUndo, "missing-track preset records no undo")
        let presetMsg = store.statusMessage
        tk.expect(presetMsg != nil, "missing track preset sets status")
        tk.expect(
            (presetMsg ?? "").localizedCaseInsensitiveContains("track")
                && (presetMsg ?? "").localizedCaseInsensitiveContains("project"),
            "status names the missing track (got: \(presetMsg ?? "nil"))")
    }

    tk.suite("AppStore V4: transport and record refuse during copilot preview") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        // Minimal valid preview state: sheet up with a non-nil pending prep.
        let fp = store.project.structuralFingerprint
        let reply = "{\"versePatch\":{\"schema\":\"verse-patch\",\"version\":1," +
            "\"fingerprint\":\"\(fp)\"," +
            "\"ops\":[{\"op\":\"setTempo\",\"bpm\":128}]}}"
        switch Copilot.preview(reply: reply, project: store.project) {
        case .success(let p):
            store.pendingCopilotPreview = p
            store.showCopilotPreview = true
        case .failure(let outcome):
            tk.expect(false, "preview should succeed for setTempo (\(outcome.userMessage))")
            return
        }
        tk.expect(store.showCopilotPreview && store.pendingCopilotPreview != nil,
                  "preview blocks transport")

        store.statusMessage = nil
        store.startPlayback()
        tk.expect(!store.isPlaying, "play refused while preview open")
        let playMsg = store.statusMessage
        tk.expect(playMsg != nil, "blocked play sets status")
        tk.expect(playMsg!.localizedCaseInsensitiveContains("preview"),
                  "play status names the preview")

        store.statusMessage = nil
        store.startRecording()
        tk.expect(!store.isRecording, "record refused while preview open")
        let recMsg = store.statusMessage
        tk.expect(recMsg != nil, "blocked record sets status")
        tk.expect(recMsg!.localizedCaseInsensitiveContains("preview"),
                  "record status names the preview")

        store.pendingCopilotPreview = nil
        store.showCopilotPreview = false
    }

    tk.suite("AppStore V4: MIDI commit surfaces when capture track is gone") {
        let (store, dir) = makeTestStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.startEngineIfNeeded()
        // Need a second track so deleteTrack is allowed after arming capture on the first.
        store.addInstrumentTrack()
        let captureID = store.project.tracks[0].id
        store.activeTrackID = captureID

        store.startRecording()
        tk.expect(store.isRecording, "armed for capture")
        store.startPlayback()
        tk.expect(store.isPlaying, "playing during capture")
        _ = waitUntilAppStore(timeout: 1.0) { (store.playbackBeat ?? 0) > 0.05 }

        store.handleMIDIEvents([.noteOn(channel: 0, note: 60, velocity: 100)])
        let onBeat = store.playbackBeat ?? 0
        _ = waitUntilAppStore(timeout: 2.0) { (store.playbackBeat ?? 0) >= onBeat + 0.3 }
        store.handleMIDIEvents([.noteOff(channel: 0, note: 60, velocity: 0)])

        // Delete the capture track while the take still has notes pending.
        store.deleteTrack(captureID)
        tk.expect(store.project.track(id: captureID) == nil, "capture track removed")

        store.statusMessage = nil
        store.stopRecording()
        store.stopPlayback()
        store.panic()

        let msg = store.statusMessage
        tk.expect(msg != nil, "lost capture track sets status")
        tk.expect(
            msg!.localizedCaseInsensitiveContains("track is gone")
                || msg!.localizedCaseInsensitiveContains("couldn’t save")
                || msg!.localizedCaseInsensitiveContains("couldn't save"),
            "status explains the MIDI take was not saved")
        // No "Record MIDI" undo: commit refused rather than inventing a home for the notes.
        tk.expect(store.undoName != "Record MIDI", "refused commit does not push Record MIDI")
        for t in store.project.tracks {
            let notes = t.clips.flatMap { $0.midiNotes ?? [] }
            tk.expect(notes.isEmpty, "no silent note dump onto remaining tracks")
        }
    }
}
