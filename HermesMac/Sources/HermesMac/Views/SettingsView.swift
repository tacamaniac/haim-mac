import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @AppStorage("bridgePort") private var bridgePort: Int = 8765
    @AppStorage("bridgeLogLevel") private var bridgeLogLevel: String = "INFO"
    @AppStorage("showThinkingDeltas") private var showThinkingDeltas: Bool = false
    @AppStorage("playResponseChime") private var playResponseChime: Bool = true
    @AppStorage("defaultAgentId") private var defaultAgentId: String = "callie"

    var body: some View {
        Form {
            Section("Bridge") {
                LabeledContent("URL") {
                    Text("http://127.0.0.1:\(bridgePort)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.bridgeAvailable ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(store.bridgeAvailable ? "Connected" : "Offline")
                            .foregroundStyle(.secondary)
                        Button("Refresh") {
                            Task { await store.checkBridge() }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            Section("Defaults") {
                Picker("Default agent", selection: $defaultAgentId) {
                    ForEach(store.availableAgents) { agent in
                        Text("\(agent.emoji) \(agent.displayName)").tag(agent.id)
                    }
                }
                .onChange(of: defaultAgentId) { _, id in
                    store.selectedAgentId = id
                }

                Toggle("Play chime when agent responds", isOn: $playResponseChime)
                Toggle("Show thinking / reasoning deltas", isOn: $showThinkingDeltas)
            }

            Section("About") {
                LabeledContent("Version") { Text("0.1.0") }
                LabeledContent("Hermes") {
                    Text(store.bridgeAvailable ? "0.15.2" : "—")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Repo") {
                    Link("tacamaniac/haim-mac",
                         destination: URL(string: "https://github.com/tacamaniac/haim-mac")!)
                }
                LabeledContent("Response sound") {
                    Link("AIM incoming message via Quick Sounds",
                         destination: URL(string: "https://quicksounds.com/sound/26674/aim-incoming-message")!)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 400)
    }
}
