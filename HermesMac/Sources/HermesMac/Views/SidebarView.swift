import SwiftUI

struct SidebarView: View {
    @Environment(SessionStore.self) private var store
    @State private var searchText = ""
    @State private var showingAgentPicker = false
    @State private var sessionPendingDeletion: Session?

    private var filtered: [Session] {
        guard !searchText.isEmpty else { return store.sessions }
        let q = searchText.lowercased()
        return store.sessions.filter {
            $0.displayTitle.lowercased().contains(q) ||
            $0.preview.lowercased().contains(q)
        }
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            List(selection: $store.selectedSessionId) {
                ForEach(filtered) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .contextMenu {
                            Button("Delete Conversation", systemImage: "trash", role: .destructive) {
                                sessionPendingDeletion = session
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
            .onChange(of: store.selectedSessionId) { _, newId in
                guard let id = newId else { return }
                store.select(id: id)
            }
            .overlay {
                if store.isLoading && store.sessions.isEmpty {
                    ProgressView()
                } else if !store.isLoading && store.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Conversations",
                        systemImage: "bubble.left",
                        description: Text("Start a new chat above.")
                    )
                }
            }

            // ── Agent selector footer ─────────────────────────────────
            Divider()
            Button {
                showingAgentPicker = true
            } label: {
                HStack(spacing: 8) {
                    Text(store.selectedAgent?.emoji ?? "🤖")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.selectedAgent?.displayName ?? "Callie")
                            .font(.callout.weight(.medium))
                        Text("Tap to change agent")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(.background)
        }
        .navigationTitle("Hermes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.newConversation() }
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat (⌘N)")
            }
        }
        .sheet(isPresented: $showingAgentPicker) {
            AgentPickerSheet(isPresented: $showingAgentPicker)
                .environment(store)
        }
        .alert(
            "Delete Conversation?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            ),
            presenting: sessionPendingDeletion
        ) { session in
            Button("Delete", role: .destructive) {
                Task { await store.deleteConversation(id: session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("This permanently deletes \"\(session.displayTitle)\". Saved Hermes memories are not affected.")
        }
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.displayTitle)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(session.updatedDate, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
