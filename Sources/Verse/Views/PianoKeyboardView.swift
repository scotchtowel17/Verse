import SwiftUI

/// An on-screen piano. Click/hold a key to play; held notes (from mouse OR computer keyboard)
/// are highlighted. Plain and finger-friendly per the amateur-first UX mandate.
struct PianoKeyboardView: View {
    let baseC: Int                 // MIDI pitch of the leftmost C
    let octaves: Int
    let held: Set<Int>
    var noteOn: (Int) -> Void
    var noteOff: (Int) -> Void

    private static let whiteSemis = [0, 2, 4, 5, 7, 9, 11]
    // White-key indices (within an octave) that have a black key to their upper-right.
    private static let blackAfter = [0, 1, 3, 4, 5]

    private var whiteCount: Int { octaves * 7 + 1 } // +1 trailing C

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(whiteCount)
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // White keys
                HStack(spacing: 0) {
                    ForEach(0..<whiteCount, id: \.self) { i in
                        let pitch = whitePitch(i)
                        PianoKey(isBlack: false, isHeld: held.contains(pitch),
                                 onPress: { noteOn(pitch) }, onRelease: { noteOff(pitch) })
                            .frame(width: w, height: h)
                    }
                }
                // Black keys overlaid
                ForEach(blackPitches(), id: \.pitch) { item in
                    PianoKey(isBlack: true, isHeld: held.contains(item.pitch),
                             onPress: { noteOn(item.pitch) }, onRelease: { noteOff(item.pitch) })
                        .frame(width: w * 0.62, height: h * 0.62)
                        .offset(x: CGFloat(item.whiteIndex + 1) * w - (w * 0.31), y: 0)
                }
            }
        }
        .frame(height: 150)
        .background(.black.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.15)))
    }

    private func whitePitch(_ i: Int) -> Int {
        baseC + (i / 7) * 12 + Self.whiteSemis[i % 7]
    }

    private func blackPitches() -> [(pitch: Int, whiteIndex: Int)] {
        var out: [(Int, Int)] = []
        for oct in 0..<octaves {
            for wi in Self.blackAfter {
                let whiteIndex = oct * 7 + wi
                let pitch = baseC + oct * 12 + Self.whiteSemis[wi] + 1
                out.append((pitch, whiteIndex))
            }
        }
        return out.map { (pitch: $0.0, whiteIndex: $0.1) }
    }
}

private struct PianoKey: View {
    let isBlack: Bool
    let isHeld: Bool
    var onPress: () -> Void
    var onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        let base: Color = isBlack ? .black : .white
        let highlight: Color = isBlack ? Color(red: 0.30, green: 0.55, blue: 1.0)
                                       : Color(red: 0.70, green: 0.82, blue: 1.0)
        RoundedRectangle(cornerRadius: isBlack ? 3 : 4)
            .fill(isHeld ? highlight : base)
            .overlay(RoundedRectangle(cornerRadius: isBlack ? 3 : 4)
                .strokeBorder(.black.opacity(isBlack ? 0.0 : 0.25), lineWidth: 0.5))
            .shadow(color: isBlack ? .black.opacity(0.4) : .clear, radius: isBlack ? 2 : 0, y: 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true; onPress() } }
                    .onEnded { _ in pressed = false; onRelease() }
            )
    }
}
