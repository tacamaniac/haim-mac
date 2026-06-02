import AppKit
import Foundation
import Observation

// MARK: - Chime

private func playChime() {
    // Default ON: play unless the user has explicitly turned it off.
    let pref = UserDefaults.standard.object(forKey: "playResponseChime")
    guard pref == nil || (pref as? Bool) == true else { return }

    if let url = Bundle.main.url(forResource: "AIMIncomingMessage", withExtension: "mp3"),
       let sound = NSSound(contentsOf: url, byReference: false) {
        sound.play()
        return
    }

    // Keep a system fallback so development builds still chime if the resource is missing.
    let paths = [
        "/System/Library/Sounds/Tink.aiff",
        "/System/Library/Sounds/Ping.aiff",
        "/System/Library/Sounds/Pop.aiff",
    ]
    for path in paths {
        if let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.play()
            return
        }
    }
}

// MARK: - ConversationStore

@Observable
@MainActor
final class ConversationStore {
    let sessionId: String              // stable key (DB id or new TUI id)
    private(set) var activeTuiId: String?  // TUI session used for sending (nil until resumed/created)

    var messages: [Message] = []
    var isStreaming = false
    var isResuming = false
    var isCompressing = false
    var usage: SessionUsage? = nil
    var activeRequestId: String? = nil
    var error: String? = nil
    var isLoadingHistory = false

    var onTurnComplete: (() async -> Void)? = nil

    private let client = BridgeClient()

    // For new sessions, activeTuiId == sessionId immediately.
    // For resumed DB sessions, activeTuiId is set after startResume() completes.
    init(sessionId: String, activeTuiId: String? = nil, agentId: String = "callie") {
        self.sessionId = sessionId
        self.activeTuiId = activeTuiId
        self.agentId = agentId
    }

    private(set) var agentId: String = "callie"

    var isReadyToChat: Bool { activeTuiId != nil && !isResuming && !isCompressing }

    // MARK: History

    func loadHistory() async {
        guard messages.isEmpty, !isLoadingHistory else { return }
        isLoadingHistory = true
        do {
            messages = try await client.fetchMessages(sessionId: sessionId)
        } catch {
            self.error = "Could not load history: \(error.localizedDescription)"
        }
        isLoadingHistory = false
    }

    // MARK: Resume

    func startResume(agentId: String) async {
        guard activeTuiId == nil, !isResuming else { return }
        isResuming = true
        error = nil
        do {
            let resumed = try await client.resumeSession(from: sessionId, agentId: agentId)
            activeTuiId = resumed.id
            await refreshUsage()
        } catch {
            self.error = "Could not resume session: \(error.localizedDescription)"
        }
        isResuming = false
    }

    // MARK: Send

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, isReadyToChat else { return }
        guard let tuiId = activeTuiId else { return }

        error = nil

        let userMsg = Message(id: UUID().uuidString, role: "user",
                              content: trimmed, createdAt: Date().timeIntervalSince1970)
        messages.append(userMsg)

        let assistantId = UUID().uuidString
        var placeholder = Message(id: assistantId, role: "assistant",
                                  content: "", createdAt: Date().timeIntervalSince1970)
        placeholder.isStreaming = true
        messages.append(placeholder)
        isStreaming = true

        do {
            let requestId = try await client.sendMessage(sessionId: tuiId, text: trimmed)
            activeRequestId = requestId
            var chimePlayedThisTurn = false

            for try await event in client.streamResponse(requestId: requestId) {
                switch event {
                case .assistantStarted:
                    break

                case .tokenDelta(let chunk):
                    // Chime on the first token — feels like "message arrived" not "message sent".
                    if !chimePlayedThisTurn {
                        chimePlayedThisTurn = true
                        playChime()
                    }
                    updateMessage(id: assistantId) { $0.content += chunk }

                case .assistantCompleted(let final, _):
                    updateMessage(id: assistantId) {
                        if !final.isEmpty { $0.content = final }
                        $0.isStreaming = false
                    }
                    isStreaming = false
                    activeRequestId = nil
                    await refreshUsage()
                    await onTurnComplete?()

                case .assistantFailed(let msg):
                    updateMessage(id: assistantId) {
                        $0.content = "⚠️ \(msg)"
                        $0.isStreaming = false
                    }
                    isStreaming = false
                    activeRequestId = nil
                    error = msg

                default:
                    break
                }
            }
        } catch {
            updateMessage(id: assistantId) {
                $0.content = "⚠️ \(error.localizedDescription)"
                $0.isStreaming = false
            }
            isStreaming = false
            activeRequestId = nil
            self.error = error.localizedDescription
        }
    }

    // MARK: Retry

    func refreshUsage() async {
        guard let tuiId = activeTuiId else { return }
        usage = try? await client.fetchUsage(sessionId: tuiId)
    }

    func compress() async {
        guard let tuiId = activeTuiId, !isStreaming, !isCompressing else { return }
        isCompressing = true
        error = nil
        do {
            usage = try await client.compressSession(id: tuiId)
        } catch {
            self.error = "Could not compress context: \(error.localizedDescription)"
        }
        isCompressing = false
    }

    // MARK: Retry

    func retry() async {
        // Re-send the last user message if the last assistant message failed.
        guard !isStreaming else { return }
        let userMessages = messages.filter { $0.isUser }
        guard let lastUser = userMessages.last else { return }
        // Remove the failed assistant message
        if let lastIdx = messages.indices.last,
           !messages[lastIdx].isUser {
            messages.removeLast()
        }
        // Remove the user message too so send() re-adds it
        messages.removeLast()
        error = nil
        await send(lastUser.content)
    }

    // MARK: Cancel

    func cancel() async {
        guard let rid = activeRequestId else { return }
        await client.cancelRequest(requestId: rid)
        updateMessage(where: { $0.isStreaming }) { $0.isStreaming = false }
        isStreaming = false
        activeRequestId = nil
    }

    // MARK: Helpers

    private func updateMessage(id: String, transform: (inout Message) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&messages[idx])
    }

    private func updateMessage(where predicate: (Message) -> Bool, transform: (inout Message) -> Void) {
        guard let idx = messages.firstIndex(where: predicate) else { return }
        transform(&messages[idx])
    }
}

// MARK: - SessionStore

@Observable
@MainActor
final class SessionStore {
    var sessions: [Session] = []
    var agents: [Agent] = []
    var selectedSessionId: String? = nil
    var selectedAgentId: String = "callie"   // persists across new chats
    var conversations: [String: ConversationStore] = [:]
    var isLoading = false
    var bridgeAvailable = true
    var error: String? = nil

    private let client = BridgeClient()

    var selectedAgent: Agent? { agents.first(where: { $0.id == selectedAgentId }) }
    var availableAgents: [Agent] { agents.filter(\.available) }

    var selectedConversation: ConversationStore? {
        guard let sid = selectedSessionId else { return nil }
        return conversations[sid]
    }

    // MARK: Bridge

    func checkBridge() async {
        bridgeAvailable = (try? await client.checkHealth()) ?? false
    }

    func load() async {
        isLoading = true
        error = nil
        for _ in 0..<30 {
            if (try? await client.checkHealth()) == true {
                bridgeAvailable = true
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        async let fetchedSessions = client.fetchSessions()
        async let fetchedAgents = client.fetchAgents()
        do {
            sessions = try await fetchedSessions
            agents = try await fetchedAgents
        } catch {
            self.error = error.localizedDescription
            bridgeAvailable = false
        }
        isLoading = false
    }

    // MARK: Session actions

    func newConversation() async {
        do {
            let session = try await client.createSession(agentId: selectedAgentId)
            sessions.insert(session, at: 0)
            let conv = ConversationStore(sessionId: session.id, activeTuiId: session.id,
                                         agentId: selectedAgentId)
            wire(conv, id: session.id)
            conversations[session.id] = conv
            selectedSessionId = session.id
        } catch {
            self.error = "Could not create session: \(error.localizedDescription)"
        }
    }

    func select(id: String) {
        selectedSessionId = id
        guard conversations[id] == nil else { return }

        let conv = ConversationStore(sessionId: id)
        wire(conv, id: id)
        conversations[id] = conv

        Task {
            // Load display history immediately (fast — reads from DB).
            await conv.loadHistory()
            // Resume in background so model has context when user sends.
            // This takes 15–30 s the first time (agent build + plugin discovery).
            await conv.startResume(agentId: "callie")
        }
    }

    func deleteConversation(id: String) async {
        do {
            if let conversation = conversations[id], conversation.isStreaming {
                await conversation.cancel()
            }
            try await client.deleteSession(id: id)
            sessions.removeAll { $0.id == id }
            conversations[id] = nil
            if selectedSessionId == id {
                selectedSessionId = nil
            }
        } catch {
            self.error = "Could not delete conversation: \(error.localizedDescription)"
        }
    }

    // MARK: Sidebar title refresh

    func refreshSession(id: String) async {
        // Give Hermes's title-generation a moment to write to the DB.
        try? await Task.sleep(for: .seconds(2))
        do {
            let updated = try await client.fetchSessions()
            sessions = updated
        } catch {}
    }

    // MARK: Private

    private func wire(_ conv: ConversationStore, id: String) {
        conv.onTurnComplete = { [weak self] in
            await self?.refreshSession(id: id)
        }
    }
}
