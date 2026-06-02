import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .environment(store)
        } detail: {
            if let conv = store.selectedConversation {
                ChatView()
                    .environment(conv)
                    .environment(store)
                    .id(conv.sessionId) // force full rebuild on session switch
            } else {
                WelcomeView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task { await store.load() }
        .overlay(alignment: .bottom) {
            if !store.bridgeAvailable {
                BridgeOfflineBanner()
            }
        }
    }
}

// MARK: - Welcome placeholder

struct WelcomeView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Hermes")
                .font(.largeTitle.weight(.semibold))
            Text("Select a conversation or start a new one.")
                .foregroundStyle(.secondary)
            Button("New Chat") {
                Task { await store.newConversation() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Bridge offline banner

struct BridgeOfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Hermes bridge could not start. Check the app settings and try again.")
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }
}
