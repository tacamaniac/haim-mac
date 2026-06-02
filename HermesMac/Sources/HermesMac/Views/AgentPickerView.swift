import SwiftUI

// MARK: - Sheet

struct AgentPickerSheet: View {
    @Environment(SessionStore.self) private var store
    @Binding var isPresented: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Text("Choose Your Agent")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding()

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(store.agents) { agent in
                        AgentCard(agent: agent, isSelected: store.selectedAgentId == agent.id) {
                            guard agent.available else { return }
                            store.selectedAgentId = agent.id
                            isPresented = false
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 380)
    }
}

// MARK: - Card

struct AgentCard: View {
    let agent: Agent
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Text(agent.emoji)
                    .font(.system(size: 28))
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(agent.displayName)
                            .font(.body.weight(.semibold))
                        if !agent.available {
                            Text("Unavailable")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(agent.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .opacity(agent.available ? 1 : 0.45)
        .disabled(!agent.available)
    }
}

// MARK: - Inline badge (shown in sidebar / chat header)

struct AgentBadge: View {
    let agent: Agent?
    var compact: Bool = false

    var body: some View {
        if let agent {
            HStack(spacing: 4) {
                Text(agent.emoji)
                    .font(compact ? .caption : .body)
                if !compact {
                    Text(agent.displayName)
                        .font(.callout.weight(.medium))
                }
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 4)
            .background(.regularMaterial, in: Capsule())
        }
    }
}
