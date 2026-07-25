import SwiftUI
import VerseAI

/// The Claude copilot bridge UI (Build Contract §15). No API key, no billing: it builds a
/// request you paste into your own Claude, and applies the `verse-patch` reply you paste back
/// only after a mandatory plain-English preview built from validated ops (never from Claude’s
/// free-form summary).
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
                    .disabled(store.showCopilotPreview)
            }

            Text("1. Describe what you'd like. 2. Copy the request into Claude. 3. Paste Claude's reply back and review the changes before applying. Uses your existing Claude — no API key or billing.")
                .font(.callout).foregroundStyle(.secondary)

            Text("What would you like Claude to do?").font(.headline)
            TextField("e.g. Add a simple 4-chord pop progression in the song key and a bass line",
                      text: $store.copilotPrompt, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .disabled(store.showCopilotPreview)

            HStack {
                Button { store.copyRequestToClipboard() } label: {
                    Label("Copy request for Claude", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.showCopilotPreview)
                Spacer()
            }

            Divider()

            HStack {
                Text("Claude's reply").font(.headline)
                Spacer()
                Button { store.pasteReplyFromClipboard() } label: {
                    Label("Paste reply", systemImage: "clipboard")
                }
                .disabled(store.showCopilotPreview)
            }
            TextEditor(text: $store.copilotReply)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.15)))
                .disabled(store.showCopilotPreview)

            HStack {
                Button { store.applyCopilotReply() } label: {
                    Label("Review changes…", systemImage: "checklist")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.copilotReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || store.showCopilotPreview)

                Button("Undo last", systemImage: "arrow.uturn.backward") { store.undo() }
                    .disabled(!store.canUndo || store.showCopilotPreview)
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
        .sheet(isPresented: Binding(
            get: { store.showCopilotPreview },
            set: { if !$0 { store.cancelCopilotPreview() } }
        )) {
            CopilotPreviewSheet()
                .environment(store)
        }
    }
}

/// Mandatory approval sheet. Approval text is `pendingCopilotPreview.description` (from
/// `TypedOp` only). Claude’s summary, if present, is labeled “Claude says:” and is not
/// the approval text.
struct CopilotPreviewSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review changes before applying")
                .font(.title3.bold())

            Text("These are the changes Verse will make. Read them carefully, then Apply or Cancel.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Approval text: rendered exclusively from validated TypedOp values.
            ScrollView {
                Text(store.pendingCopilotPreview?.description ?? "(No changes)")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 140, maxHeight: 280)
            .padding(10)
            .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            if let claude = store.pendingCopilotPreview?.claudeSummary,
               !claude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude says:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(claude)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(.black.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Cancel") { store.cancelCopilotPreview() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    store.commitCopilotPreview()
                } label: {
                    Label("Apply", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.pendingCopilotPreview == nil)
            }
        }
        .padding(20)
        .frame(width: 480, height: 440)
        .interactiveDismissDisabled(false)
    }
}
