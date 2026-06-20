import SwiftUI

/// The Claude copilot bridge UI (Build Contract §15). No API key, no billing: it builds a
/// request you paste into your own Claude, and applies the `verse-patch` reply you paste back.
struct CopilotPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Songwriting copilot", systemImage: "sparkles")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
            }

            Text("1. Describe what you'd like. 2. Copy the request into Claude. 3. Paste Claude's reply back and apply. Uses your existing Claude — no API key or billing.")
                .font(.callout).foregroundStyle(.secondary)

            Text("What would you like Claude to do?").font(.headline)
            TextField("e.g. Add a simple 4-chord pop progression in the song key and a bass line",
                      text: $store.copilotPrompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button { store.copyRequestToClipboard() } label: {
                    Label("Copy request for Claude", systemImage: "doc.on.clipboard")
                }.buttonStyle(.borderedProminent)
                Spacer()
            }

            Divider()

            HStack {
                Text("Claude's reply").font(.headline)
                Spacer()
                Button { store.pasteReplyFromClipboard() } label: {
                    Label("Paste reply", systemImage: "clipboard")
                }
            }
            TextEditor(text: $store.copilotReply)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.15)))

            HStack {
                Button { store.applyCopilotReply() } label: {
                    Label("Apply to my song", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.copilotReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Undo last", systemImage: "arrow.uturn.backward") { store.undo() }
                    .disabled(!store.canUndo)
                Spacer()
            }

            if let msg = store.copilotMessage {
                ScrollView {
                    Text(msg).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .padding(8)
                .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
    }
}
