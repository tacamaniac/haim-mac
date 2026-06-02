import SwiftUI

struct ComposerView: View {
    @Environment(ConversationStore.self) private var conv
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            contextStatus
            HStack(alignment: .bottom, spacing: 8) {
                editor

                if conv.isStreaming {
                    cancelButton
                } else {
                    sendButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var contextStatus: some View {
        if let usage = conv.usage, usage.contextMax > 0 {
            HStack(spacing: 8) {
                ProgressView(value: Double(usage.contextPercent), total: 100)
                    .tint(contextColor(for: usage.contextPercent))
                    .frame(width: 72)
                Text("Context \(usage.contextUsed.formatted()) / \(usage.contextMax.formatted()) · \(usage.contextPercent)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if usage.contextPercent >= 80 {
                    Button(conv.isCompressing ? "Compressing…" : "Compress") {
                        Task { await conv.compress() }
                    }
                    .font(.caption)
                    .disabled(conv.isStreaming || conv.isCompressing)
                }
            }
        }
    }

    private func contextColor(for percent: Int) -> Color {
        if percent >= 90 { return .red }
        if percent >= 80 { return .orange }
        return .secondary
    }

    private var editor: some View {
        TextField("Message…", text: $text, axis: .vertical)
            .lineLimit(1...8)
            .textFieldStyle(.plain)
            .focused($focused)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onSubmit { submitIfReady() }
            .onAppear { focused = true }
    }

    private var sendButton: some View {
        Button(action: submitIfReady) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: [])
        .help("Send (Return)")
    }

    private var cancelButton: some View {
        Button {
            Task { await conv.cancel() }
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Cancel")
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !conv.isStreaming
            && conv.isReadyToChat
    }

    private func submitIfReady() {
        guard canSend else { return }
        let msg = text
        text = ""
        Task { await conv.send(msg) }
    }
}
