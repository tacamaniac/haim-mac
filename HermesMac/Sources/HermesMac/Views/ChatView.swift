import SwiftUI

struct ChatView: View {
    @Environment(ConversationStore.self) private var conv
    @Environment(SessionStore.self) private var store
    @State private var scrolledToBottom = true

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                messageList
                Divider()
                ComposerView()
                    .environment(conv)
            }
            resumingOverlay
        }
        .background(.background)
        .navigationTitle("")
        .toolbar { statusRow }
    }

    // MARK: Resume overlay

    @ViewBuilder
    private var resumingOverlay: some View {
        if conv.isResuming {
            VStack(spacing: 12) {
                ProgressView()
                Text("Reconnecting session…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.opacity(0.85))
        }
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(conv.messages) { msg in
                        MessageRow(message: msg, onRetry: msg.content.hasPrefix("⚠️") ? {
                            Task { await conv.retry() }
                        } : nil)
                        .id(msg.id)
                    }
                    // Bottom anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: conv.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: conv.messages.last?.content) { _, _ in
                if conv.isStreaming {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .overlay {
                if conv.isLoadingHistory {
                    ProgressView()
                } else if conv.messages.isEmpty && !conv.isLoadingHistory {
                    emptyState
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Start the conversation")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Toolbar status row

    @ToolbarContentBuilder
    private var statusRow: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            AgentBadge(agent: store.agents.first(where: { $0.id == conv.agentId }))
        }
        ToolbarItem(placement: .status) {
            if conv.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Hermes is responding…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItem(placement: .status) {
            if let err = conv.error {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }
}
