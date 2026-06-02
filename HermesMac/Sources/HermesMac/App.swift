import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "HermesDockIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        BridgeSupervisor.shared.startIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BridgeSupervisor.shared.stopOwnedBridge()
    }
}

@main
struct HermesMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = SessionStore()
    @State private var showSettings = false

    var body: some Scene {
        // ── Main window ───────────────────────────────────────────────
        WindowGroup {
            ContentView()
                .environment(store)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // Replace the default New Item with our New Chat
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    Task { @MainActor in await store.newConversation() }
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // Hermes menu
            CommandMenu("Hermes") {
                Button("New Chat") {
                    Task { @MainActor in await store.newConversation() }
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Settings…") {
                    showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // ── Settings window ───────────────────────────────────────────
        Window("Settings", id: "settings") {
            SettingsView()
                .environment(store)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 320)

        // ── Menu bar extra ────────────────────────────────────────────
        MenuBarExtra("Hermes", systemImage: "bubble.left.fill") {
            MenuBarView()
                .environment(store)
        }
        .menuBarExtraStyle(.window)
    }
}
