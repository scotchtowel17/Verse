import Foundation
import CoreMIDI

/// Live MIDI input via CoreMIDI. Enumerates sources, connects an input port, handles hot-plug,
/// and delivers decoded events on the main queue.
///
/// **Threading:** CoreMIDI packet callbacks arrive on a high-priority MIDI thread.
/// `VerseAudioEngine` is main-thread-only. This type always hops to the main queue before
/// invoking `onEvents` or `onSourcesChanged`. Never call the audio engine from a MIDI callback.
///
/// **Hot-plug:** CoreMIDI setup notifications (`msgSetupChanged`, object added/removed) re-scan
/// sources and connect new endpoints / drop vanished ones. A controller plugged in after launch
/// is picked up without restarting the app.
public final class MIDIInput: @unchecked Sendable {

    public private(set) var sourceNames: [String] = []

    /// Called on the main queue when sources appear, disappear, or are renamed.
    public var onSourcesChanged: (([String]) -> Void)?

    /// Called on the main queue for each batch of decoded channel-voice events.
    public var onEvents: (([MIDIEvent]) -> Void)?

    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    /// Connected sources keyed by CoreMIDI unique ID (stable across re-enumeration).
    private var connectedByUniqueID: [MIDIUniqueID: MIDIEndpointRef] = [:]
    /// Holds CoreMIDI blocks so they do not capture `self` mid-init (weak self would be nil).
    private let callbacks = CallbackBox()
    /// Coalesces bursty setup notifications into one rescan on the main queue.
    private var rescanPending = false

    /// Create a CoreMIDI client and input port, then connect every current source.
    /// Throws a plain-language error if CoreMIDI setup fails.
    public init(clientName: String = "Verse") throws {
        let box = callbacks

        var clientRef: MIDIClientRef = 0
        // Notification block: CoreMIDI may call this off the main thread.
        // Route through CallbackBox so the block is valid for the client lifetime without
        // capturing an uninitialized `self`.
        let clientStatus = MIDIClientCreateWithBlock(clientName as CFString, &clientRef) { notification in
            box.onNotify?(notification)
        }
        guard clientStatus == noErr else {
            throw MIDIInputError.setupFailed("Couldn’t create a MIDI client (error \(clientStatus)).")
        }
        client = clientRef

        var portRef: MIDIPortRef = 0
        // Packet block: always on a CoreMIDI thread. Decode here, hop to main for delivery.
        let portStatus = MIDIInputPortCreateWithBlock(
            client,
            "\(clientName) Input" as CFString,
            &portRef
        ) { packetList, _ in
            box.onPacket?(packetList)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            client = 0
            throw MIDIInputError.setupFailed("Couldn’t open a MIDI input port (error \(portStatus)).")
        }
        port = portRef

        // Wire callbacks only after all stored properties are set.
        box.onNotify = { [weak self] notification in
            self?.handleNotification(notification)
        }
        box.onPacket = { [weak self] packetList in
            self?.handlePacketList(packetList)
        }

        rescanSources()
    }

    deinit {
        callbacks.onNotify = nil
        callbacks.onPacket = nil
        if port != 0 {
            for src in connectedByUniqueID.values {
                MIDIPortDisconnectSource(port, src)
            }
            connectedByUniqueID.removeAll()
            MIDIPortDispose(port)
            port = 0
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
    }

    /// Re-enumerate sources and connect any new ones / drop any that vanished.
    /// Safe to call after hot-plug notifications and from tests.
    public func rescanSources() {
        guard port != 0 else { return }

        var seen: [MIDIUniqueID: MIDIEndpointRef] = [:]
        var names: [String] = []
        let count = MIDIGetNumberOfSources()
        if count > 0 {
            for i in 0..<count {
                let src = MIDIGetSource(i)
                guard src != 0 else { continue }
                var uid: MIDIUniqueID = 0
                let idStatus = MIDIObjectGetIntegerProperty(src, kMIDIPropertyUniqueID, &uid)
                // Fall back to the endpoint ref as a key if unique ID is unavailable.
                let key: MIDIUniqueID = (idStatus == noErr) ? uid : MIDIUniqueID(bitPattern: UInt32(src))

                if let existing = connectedByUniqueID[key] {
                    // Already connected: keep the connection, do not connect twice.
                    seen[key] = existing
                    names.append(Self.displayName(for: existing))
                    continue
                }

                let status = MIDIPortConnectSource(port, src, nil)
                if status == noErr {
                    seen[key] = src
                    names.append(Self.displayName(for: src))
                }
            }
        }

        // Disconnect sources that disappeared.
        for (key, src) in connectedByUniqueID where seen[key] == nil {
            MIDIPortDisconnectSource(port, src)
        }
        connectedByUniqueID = seen

        let sorted = names.sorted()
        let changed = sorted != sourceNames
        sourceNames = sorted
        if changed {
            publishSourcesOnMain(sorted)
        }
    }

    // MARK: - CoreMIDI callbacks (MIDI thread or arbitrary queue)

    private func handleNotification(_ notification: UnsafePointer<MIDINotification>) {
        // Read messageID only: the pointer is valid solely for this call.
        let messageID = notification.pointee.messageID
        switch messageID {
        case .msgObjectAdded, .msgObjectRemoved, .msgSetupChanged, .msgPropertyChanged:
            scheduleRescanFromNotification()
        default:
            break
        }
    }

    /// Coalesce notification storms (added + setupChanged often fire together) onto one main-queue rescan.
    private func scheduleRescanFromNotification() {
        // Always hop off the notification thread before touching connection state / UI.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Collapse back-to-back notifications in the same turn into a single rescan.
            if self.rescanPending { return }
            self.rescanPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rescanPending = false
                self.rescanSources()
                // CoreMIDI can publish the endpoint slightly after the first notification.
                // A short follow-up rescan catches sources that were not yet visible.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.rescanSources()
                }
            }
        }
    }

    private func handlePacketList(_ packetList: UnsafePointer<MIDIPacketList>) {
        var bytes: [UInt8] = []
        let numPackets = Int(packetList.pointee.numPackets)
        // First packet is embedded in the list; further packets follow in the same buffer.
        // Walk via MIDIPacketNext on a pointer into that buffer (not a local copy).
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet)!
        var packet = UnsafeRawPointer(packetList)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<numPackets {
            let length = Int(packet.pointee.length)
            withUnsafeBytes(of: packet.pointee.data) { raw in
                let buf = raw.bindMemory(to: UInt8.self)
                bytes.append(contentsOf: buf.prefix(length))
            }
            packet = UnsafePointer(MIDIPacketNext(packet))
        }

        let events = MIDIParser.parse(bytes)
        guard !events.isEmpty else { return }

        // Correctness: hop to main before any engine or AppStore work.
        DispatchQueue.main.async { [weak self] in
            self?.onEvents?(events)
        }
    }

    private func publishSourcesOnMain(_ names: [String]) {
        if Thread.isMainThread {
            onSourcesChanged?(names)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onSourcesChanged?(names)
            }
        }
    }

    private static func displayName(for endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
        if status == noErr, let cf = name?.takeRetainedValue() {
            let s = cf as String
            if !s.isEmpty { return s }
        }
        var cn: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &cn) == noErr,
           let cf = cn?.takeRetainedValue() {
            let s = cf as String
            if !s.isEmpty { return s }
        }
        return "MIDI device"
    }
}

/// Mutable box so CoreMIDI create-blocks can call into the owner after `init` finishes.
private final class CallbackBox: @unchecked Sendable {
    var onNotify: ((UnsafePointer<MIDINotification>) -> Void)?
    var onPacket: ((UnsafePointer<MIDIPacketList>) -> Void)?
}

public enum MIDIInputError: Error, LocalizedError {
    case setupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .setupFailed(let message): return message
        }
    }
}
