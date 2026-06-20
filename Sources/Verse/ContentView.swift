import SwiftUI
import VerseModel

/// M0 placeholder content. Replaced by the real workspace (keyboard, tracks, transport)
/// in M1–M4. Kept deliberately plain-language per the amateur-first UX mandate.
struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Text("Verse")
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("“\(store.project.title)”")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("\(store.project.tracks.count) track(s) · \(Int(store.project.tempoBPM ?? 120)) BPM")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Your songwriting workspace is loading, milestone by milestone.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
