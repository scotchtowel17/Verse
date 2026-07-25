import Foundation
import CoreMIDI
import VerseMIDI
import VerseAppCore
import VerseModel
import VerseEngine

/// Phase M: pure MIDI parse checks plus end-to-end delivery via a virtual CoreMIDI source.
/// Physical controllers (Akai MPK mini, etc.) are not attached in this harness.
func runMIDIChecks(_ tk: TestKit) {
    // Parser is pure and main-thread-free.
    runMIDIParserChecks(tk)

    // Live CoreMIDI + AppStore need the main actor / main run loop.
    if Thread.isMainThread {
        MainActor.assumeIsolated { runMIDILiveChecks(tk) }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { runMIDILiveChecks(tk) }
        }
    }
}

// MARK: - Pure parser (no CoreMIDI)

private func runMIDIParserChecks(_ tk: TestKit) {
    tk.suite("MIDI parser: note on preserves velocity and channel") {
        let events = MIDIParser.parse([0x91, 60, 100])
        tk.expectEqual(events.count, 1, "one event")
        guard case .noteOn(let ch, let note, let vel) = events.first else {
            tk.expect(false, "event is noteOn")
            return
        }
        tk.expectEqual(ch, 1, "channel 1 (0-based status nibble)")
        tk.expectEqual(note, 60, "middle C")
        tk.expectEqual(vel, 100, "velocity preserved")
    }

    tk.suite("MIDI parser: note off") {
        let events = MIDIParser.parse([0x80, 64, 64])
        tk.expectEqual(events.count, 1, "one event")
        guard case .noteOff(let ch, let note, let vel) = events.first else {
            tk.expect(false, "event is noteOff")
            return
        }
        tk.expectEqual(ch, 0, "channel 0")
        tk.expectEqual(note, 64, "pitch")
        tk.expectEqual(vel, 64, "release velocity")
    }

    tk.suite("MIDI parser: note-on velocity 0 is note-off") {
        // Most controllers including MPK mini send this instead of 0x8n.
        let events = MIDIParser.parse([0x90, 60, 0])
        tk.expectEqual(events.count, 1, "one event")
        guard case .noteOff(_, let note, let vel) = events.first else {
            tk.expect(false, "velocity-0 note-on becomes noteOff")
            return
        }
        tk.expectEqual(note, 60, "same pitch")
        tk.expectEqual(vel, 0, "zero velocity")
    }

    tk.suite("MIDI parser: control change") {
        let events = MIDIParser.parse([0xB0, 1, 64])
        tk.expectEqual(events.count, 1, "one event")
        guard case .controlChange(let ch, let cc, let val) = events.first else {
            tk.expect(false, "event is controlChange")
            return
        }
        tk.expectEqual(ch, 0, "channel")
        tk.expectEqual(cc, 1, "mod wheel")
        tk.expectEqual(val, 64, "value")
    }

    tk.suite("MIDI parser: running status and multi-message stream") {
        // Note on C, note on E (running status), note off C via velocity 0.
        let events = MIDIParser.parse([0x90, 60, 80, 64, 90, 60, 0])
        tk.expectEqual(events.count, 3, "three events")
        tk.expect(events[0] == .noteOn(channel: 0, note: 60, velocity: 80), "first note on")
        tk.expect(events[1] == .noteOn(channel: 0, note: 64, velocity: 90), "running-status note on")
        tk.expect(events[2] == .noteOff(channel: 0, note: 60, velocity: 0), "vel-0 note-off")
    }

    tk.suite("MIDI parser: stuck-note rule (on then vel-0 off clears)") {
        var held = Set<Int>()
        for e in MIDIParser.parse([0x90, 72, 110, 0x90, 72, 0]) {
            switch e {
            case .noteOn(_, let n, _): held.insert(Int(n))
            case .noteOff(_, let n, _): held.remove(Int(n))
            case .controlChange: break
            }
        }
        tk.expect(held.isEmpty, "no stuck pitch after note-on + vel-0 note-off")
    }
}

// MARK: - Live CoreMIDI (virtual source) + AppStore routing

@MainActor
private func runMIDILiveChecks(_ tk: TestKit) {

    tk.suite("MIDI input: launches with no device and lists sources") {
        // Creating MIDIInput must not throw/hang when nothing is attached.
        let input = try MIDIInput(clientName: "VerseCheck-Empty-\(UUID().uuidString)")
        // sourceNames may be empty or include system virtual ports; either is fine.
        tk.expect(true, "MIDIInput init without a physical controller")
        _ = input.sourceNames
        // Keep input alive through the assertion only.
        withExtendedLifetime(input) { _ in }
    }

    tk.suite("MIDI input: virtual source delivers note on/off on main queue") {
        let virtual = try VirtualMIDISource(name: "VerseCheck-Virt-\(UUID().uuidString.prefix(8))")
        defer { virtual.tearDown() }

        let input = try MIDIInput(clientName: "VerseCheck-In-\(UUID().uuidString.prefix(8))")
        // Hot-plug / setup change can be async; rescan and wait until our source appears.
        waitUntil(timeout: 3.0) {
            input.rescanSources()
            return input.sourceNames.contains(where: { $0.contains("VerseCheck-Virt") || $0 == virtual.name })
        }
        tk.expect(
            input.sourceNames.contains(where: { $0.contains("VerseCheck-Virt") || $0 == virtual.name }),
            "virtual source connected (names: \(input.sourceNames))"
        )

        var received: [MIDIEvent] = []
        var sawMainThread = false
        input.onEvents = { events in
            sawMainThread = Thread.isMainThread
            received.append(contentsOf: events)
        }

        virtual.send(bytes: [0x90, 60, 100])
        waitUntil(timeout: 3.0) { received.contains { if case .noteOn = $0 { return true }; return false } }

        tk.expect(sawMainThread, "onEvents delivered on main thread (engine hop)")
        tk.expect(
            received.contains(where: {
                if case .noteOn(_, 60, 100) = $0 { return true }
                return false
            }),
            "note on C vel 100 received"
        )

        received.removeAll()
        virtual.send(bytes: [0x80, 60, 40])
        waitUntil(timeout: 3.0) { received.contains { if case .noteOff = $0 { return true }; return false } }
        tk.expect(
            received.contains(where: {
                if case .noteOff(_, 60, _) = $0 { return true }
                return false
            }),
            "note off received"
        )

        received.removeAll()
        virtual.send(bytes: [0x90, 67, 0])
        waitUntil(timeout: 3.0) { !received.isEmpty }
        tk.expect(
            received.contains(where: {
                if case .noteOff(_, 67, 0) = $0 { return true }
                return false
            }),
            "virtual note-on vel 0 decoded as note-off"
        )

        withExtendedLifetime(input) { _ in }
    }

    tk.suite("MIDI AppStore: routes velocity into heldNotes and panic clears") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerseCheck-MIDI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = AppStore(recoveryBaseDir: dir)
        // Direct event path (same handler CoreMIDI uses after the main-queue hop).
        store.handleMIDIEvents([
            .noteOn(channel: 0, note: 60, velocity: 42),
            .noteOn(channel: 0, note: 64, velocity: 110),
        ])
        tk.expect(store.heldNotes.contains(60), "MIDI note on lights heldNotes (60)")
        tk.expect(store.heldNotes.contains(64), "MIDI note on lights heldNotes (64)")

        store.handleMIDIEvents([.noteOff(channel: 0, note: 60, velocity: 0)])
        tk.expect(!store.heldNotes.contains(60), "note-off removes from heldNotes")
        tk.expect(store.heldNotes.contains(64), "other held note remains")

        // Velocity-0 note-on path (parser already maps; handler still sees noteOff).
        store.handleMIDIEvents([.noteOff(channel: 0, note: 64, velocity: 0)])
        tk.expect(store.heldNotes.isEmpty, "all MIDI notes released")

        store.handleMIDIEvents([.noteOn(channel: 0, note: 72, velocity: 80)])
        tk.expect(store.heldNotes.contains(72), "note held before panic")
        store.panic()
        tk.expect(store.heldNotes.isEmpty, "panic clears MIDI-originated held notes")

        // Status string is honest when no names published.
        if store.midiSourceNames.isEmpty {
            tk.expectEqual(store.midiConnectionStatus, "No MIDI controller connected",
                           "honest empty status")
        } else {
            tk.expect(store.midiConnectionStatus.hasSuffix("connected"),
                      "status names attached sources only")
            tk.expect(!store.midiConnectionStatus.lowercased().contains("akai"),
                      "does not claim Akai without that device name in source list")
        }
    }

    tk.suite("MIDI AppStore: end-to-end virtual source updates heldNotes") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerseCheck-MIDI-E2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let virtual = try VirtualMIDISource(name: "VerseCheck-E2E-\(UUID().uuidString.prefix(8))")
        defer { virtual.tearDown() }

        let store = AppStore(recoveryBaseDir: dir)
        store.rescanMIDISources()
        waitUntil(timeout: 3.0) {
            store.rescanMIDISources()
            return store.midiSourceNames.contains(where: { $0.contains("VerseCheck-E2E") })
        }

        virtual.send(bytes: [0x90, 61, 99])
        waitUntil(timeout: 3.0) { store.heldNotes.contains(61) }
        tk.expect(store.heldNotes.contains(61), "virtual note-on reaches AppStore heldNotes")

        virtual.send(bytes: [0x90, 61, 0])
        waitUntil(timeout: 3.0) { !store.heldNotes.contains(61) }
        tk.expect(!store.heldNotes.contains(61), "virtual vel-0 note-on clears heldNotes (no stuck note)")
    }
}

// MARK: - Virtual source helper

/// A process-local CoreMIDI source used only by VerseCheck (no physical hardware).
private final class VirtualMIDISource {
    let name: String
    private var client: MIDIClientRef = 0
    private var endpoint: MIDIEndpointRef = 0

    init(name: String) throws {
        self.name = name
        var clientRef: MIDIClientRef = 0
        let cs = MIDIClientCreate(name as CFString, nil, nil, &clientRef)
        guard cs == noErr else {
            throw MIDIInputError.setupFailed("virtual client failed (\(cs))")
        }
        client = clientRef
        var endRef: MIDIEndpointRef = 0
        let es = MIDISourceCreate(client, name as CFString, &endRef)
        guard es == noErr else {
            MIDIClientDispose(client)
            client = 0
            throw MIDIInputError.setupFailed("virtual source failed (\(es))")
        }
        endpoint = endRef
    }

    func send(bytes: [UInt8]) {
        guard endpoint != 0, !bytes.isEmpty else { return }
        // Build a single-packet MIDIPacketList in a heap buffer.
        let bufferSize = 512
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: bufferSize)
        let packetList = UnsafeMutableRawPointer(buffer).bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(packetList)
        bytes.withUnsafeBufferPointer { buf in
            packet = MIDIPacketListAdd(packetList, bufferSize, packet, 0, buf.count, buf.baseAddress!)
        }
        MIDIReceived(endpoint, packetList)
    }

    func tearDown() {
        if endpoint != 0 {
            MIDIEndpointDispose(endpoint)
            endpoint = 0
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
    }

    deinit { tearDown() }
}

/// Spin the main run loop until `predicate` is true or `timeout` seconds elapse.
/// Timeout is only a wait bound (not an asserted upper performance limit).
@discardableResult
private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
    if predicate() { return true }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        if predicate() { return true }
    }
    return predicate()
}
