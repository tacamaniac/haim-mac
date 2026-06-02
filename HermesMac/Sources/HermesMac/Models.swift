import Foundation

// MARK: - Session

struct Session: Identifiable, Codable, Sendable {
    let id: String
    var title: String
    var preview: String
    var updatedAt: Double
    var messageCount: Int
    var agentId: String

    enum CodingKeys: String, CodingKey {
        case id, title, preview
        case updatedAt = "updated_at"
        case messageCount = "message_count"
        case agentId = "agent_id"
    }

    var displayTitle: String { title.isEmpty ? "New Chat" : title }
    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt) }
}

// MARK: - Message

struct Message: Identifiable, Sendable {
    let id: String
    let role: String
    var content: String
    let createdAt: Double
    var isStreaming: Bool = false

    var isUser: Bool { role == "user" }
    var createdDate: Date { Date(timeIntervalSince1970: createdAt) }
}

// Codable conformance for server messages (mutable `content` is local-only).
extension Message: Codable {
    enum CodingKeys: String, CodingKey {
        case id, role, content
        case createdAt = "created_at"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        isStreaming = false
    }
}

// MARK: - Agent

struct Agent: Identifiable, Codable, Sendable {
    let id: String
    let displayName: String
    let profile: String
    let role: String
    let description: String
    let available: Bool
    let personality: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case profile, role, description, available, personality
    }

    var emoji: String {
        switch id {
        case "callie":  return "🌸"
        case "lyra":    return "✨"
        case "piper":   return "⚡️"
        case "sage":    return "🌿"
        case "vivian":  return "💫"
        case "zero":    return "🔬"
        default:        return "🤖"
        }
    }
}

// MARK: - Bridge wire types

struct HealthResponse: Codable {
    let status: String
    let hermes: String
    let version: String
}

struct CreateSessionResponse: Codable {
    let id: String
    let agentId: String
    let title: String
    let preview: String
    let updatedAt: Double
    let messageCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case title, preview
        case updatedAt = "updated_at"
        case messageCount = "message_count"
    }

    var asSession: Session {
        Session(id: id, title: title, preview: preview,
                updatedAt: updatedAt, messageCount: messageCount, agentId: agentId)
    }
}

struct SessionUsage: Codable, Sendable {
    let model: String
    let contextUsed: Int
    let contextMax: Int
    let contextPercent: Int
    let compressions: Int

    enum CodingKeys: String, CodingKey {
        case model
        case contextUsed = "context_used"
        case contextMax = "context_max"
        case contextPercent = "context_percent"
        case compressions
    }
}

struct ChatRequestBody: Codable {
    let sessionId: String
    let agentId: String
    let message: String
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agentId = "agent_id"
        case message, stream
    }
}

struct RequestHandle: Codable {
    let requestId: String
    let sessionId: String
    let streamUrl: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case sessionId = "session_id"
        case streamUrl = "stream_url"
        case status
    }
}

// MARK: - Bridge SSE events

enum BridgeEvent: Sendable {
    case requestStarted
    case assistantStarted
    case tokenDelta(text: String)
    case toolStarted(name: String, context: String)
    case toolFinished(name: String)
    case assistantCompleted(text: String, status: String)
    case assistantFailed(message: String)
    case sessionUpdated
    case requestCompleted
    case heartbeat
    case other(type: String)
}
