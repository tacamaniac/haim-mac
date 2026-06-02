import SwiftUI

struct MenuBarView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Hermes")
                    .font(.headline)
                Spacer()
                if let agent = store.selectedAgent {
                    Text("\(agent.emoji) \(agent.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Quick-launch buttons
            Button {
                Task { @MainActor in
                    await store.newConversation()
                    NSApp.activate(ignoringOtherApps: true)
                }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Divider()

            // Recent sessions (top 5)
            if store.sessions.isEmpty {
                Text("No recent conversations")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(12)
            } else {
                ForEach(store.sessions.prefix(5)) { session in
                    Button {
                        store.select(id: session.id)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayTitle)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(session.preview.isEmpty ? " " : session.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button("Quit Hermes") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 280)
    }
}
