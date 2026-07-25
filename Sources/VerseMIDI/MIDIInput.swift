import Foundation
import CoreMIDI

/// Live MIDI input via CoreMIDI. Enumerates sources, connects an input port, handles hot-plug,
/// and delivers decoded events on the main queue.
///
/// **Threading:** CoreMIDI packet callbacks arrive on a high-priority MIDI thread.
/// `VerseAudioEngine` is main-thread-only. This type always hops to the main queue before
/// invoking `onEvents` or `onSourcesChanged`. Never call the audio engine from a MIDI callback.
public final class MIDIInput: @unchecked Sendable {

    public private(set) var sourceNames: [String] = []

    /// Called on the main queue when sources appear, disappear, or are renamed.
    public var onSourcesChanged: (([String]) -> Void)?

    /// Called on the main queue for each batch of decoded channel-voice events.
    public var onEvents: (([MIDIEvent]) -> Void)?

    private var client: MIDIClientRef = 0
    private var port: MIDIPortRef = 0
    private var connectedSources: [MIDIEndpointRef] = []

    /// Create a CoreMIDI client and input port, then connect every current source.
    /// Throws a plain-language error if CoreMIDI setup fails.
    public init(clientName: String = "Verse") throws {
        var clientRef: MIDIClientRef = 0
        // Notification block: CoreMIDI may call this off the main thread.
        let clientStatus = MIDIClientCreateWithBlock(clientName as CFString, &clientRef) { [weak self] notification in
            self?.handleNotification(notification)
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
        ) { [weak self] packetList, _ in
            self?.handlePacketList(packetList)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            client = 0
            throw MIDIInputError.setupFailed("Couldn’t open a MIDI input port (error \(portStatus)).")
        }
        port = portRef

        rescanSources()
    }

    deinit {
        if port != 0 {
            for src in connectedSources {
                MIDIPortDisconnectSource(port, src)
            }
            MIDIPortDispose(port)
            port = 0
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
    }

    /// Re-enumerate sources and reconnect. Safe to call after hot-plug notifications.
    public func rescanSources() {
        guard port != 0 else { return }

        for src in connectedSources {
            MIDIPortDisconnectSource(port, src)
        }
        connectedSources.removeAll()

        var names: [String] = []
        let count = MIDIGetNumberOfSources()
        if count > 0 {
            for i in 0..<count {
                let src = MIDIGetSource(i)
                guard src != 0 else { continue }
                let status = MIDIPortConnectSource(port, src, nil)
                if status == noErr {
                    connectedSources.append(src)
                    names.append(Self.displayName(for: src))
                }
            }
        }

        let sorted = names.sorted()
        let changed = sorted != sourceNames
        sourceNames = sorted
        if changed {
            publishSourcesOnMain(sorted)
        }
    }

    // MARK: - CoreMIDI callbacks (MIDI thread or arbitrary queue)

    private func handleNotification(_ notification: UnsafePointer<MIDINotification>) {
        let messageID = notification.pointee.messageID
        switch messageID {
        case .msgObjectAdded, .msgObjectRemoved, .msgSetupChanged, .msgPropertyChanged:
            // Always hop off the notification thread before touching source list / UI.
            DispatchQueue.main.async { [weak self] in
                self?.rescanSources()
            }
        default:
            break
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

public enum MIDIInputError: Error, LocalizedError {
    case setupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .setupFailed(let message): return message
        }
    }
}
