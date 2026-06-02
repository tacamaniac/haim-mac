import Foundation

// MARK: - SSE Parser

struct SSEParser {
    private var pendingEvent = ""
    private var pendingData = ""

    mutating func feed(_ line: String) -> BridgeEvent? {
        if line.isEmpty {
            defer { pendingEvent = ""; pendingData = "" }
            return parseEvent(type: pendingEvent, data: pendingData)
        }
        if line.hasPrefix("event: ") {
            pendingEvent = String(line.dropFirst(7))
        } else if line.hasPrefix("data: ") {
            pendingData = String(line.dropFirst(6))
        }
        return nil
    }

    private func parseEvent(type: String, data: String) -> BridgeEvent? {
        guard !type.isEmpty else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
        switch type {
        case "request.started":     return .requestStarted
        case "assistant.started":   return .assistantStarted
        case "token.delta":         return .tokenDelta(text: json["text"] as? String ?? "")
        case "tool.started":        return .toolStarted(
                                        name: json["name"] as? String ?? "",
                                        context: json["context"] as? String ?? "")
        case "tool.finished":       return .toolFinished(name: json["name"] as? String ?? "")
        case "assistant.completed": return .assistantCompleted(
                                        text: json["text"] as? String ?? "",
                                        status: json["status"] as? String ?? "complete")
        case "assistant.failed":    return .assistantFailed(message: json["message"] as? String ?? "Error")
        case "request.completed":   return .requestCompleted
        case "heartbeat":           return .heartbeat
        default:                    return .other(type: type)
        }
    }
}

// MARK: - Bridge Client

struct BridgeClient {
    static let baseURL = URL(string: "http://127.0.0.1:8765")!

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    // MARK: Agents

    func fetchAgents() async throws -> [Agent] {
        let (data, _) = try await URLSession.shared.data(from: Self.baseURL.appending(path: "agents"))
        return try decoder.decode([Agent].self, from: data)
    }

    // MARK: Health

    func checkHealth() async throws -> Bool {
        let (data, _) = try await URLSession.shared.data(from: Self.baseURL.appending(path: "health"))
        let r = try decoder.decode(HealthResponse.self, from: data)
        return r.status == "ok"
    }

    // MARK: Sessions

    func fetchSessions() async throws -> [Session] {
        let (data, _) = try await URLSession.shared.data(from: Self.baseURL.appending(path: "sessions"))
        return try decoder.decode([Session].self, from: data)
    }

    func createSession(agentId: String = "callie") async throws -> Session {
        var req = URLRequest(url: Self.baseURL.appending(path: "sessions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["agent_id": agentId])
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(CreateSessionResponse.self, from: data).asSession
    }

    func resumeSession(from sessionId: String, agentId: String = "callie") async throws -> Session {
        struct ResumeBody: Encodable {
            let agentId: String
            let resumeFrom: String
            enum CodingKeys: String, CodingKey {
                case agentId = "agent_id"
                case resumeFrom = "resume_from"
            }
        }
        var req = URLRequest(url: Self.baseURL.appending(path: "sessions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(ResumeBody(agentId: agentId, resumeFrom: sessionId))
        req.timeoutInterval = 120  // resume can take 30 s for agent build
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(CreateSessionResponse.self, from: data).asSession
    }

    func fetchMessages(sessionId: String) async throws -> [Message] {
        let url = Self.baseURL.appending(path: "sessions/\(sessionId)/messages")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode([Message].self, from: data)
    }

    func deleteSession(id: String) async throws {
        var req = URLRequest(url: Self.baseURL.appending(path: "sessions/\(id)"))
        req.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func fetchUsage(sessionId: String) async throws -> SessionUsage {
        let url = Self.baseURL.appending(path: "sessions/\(sessionId)/usage")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(SessionUsage.self, from: data)
    }

    func compressSession(id: String) async throws -> SessionUsage {
        var req = URLRequest(url: Self.baseURL.appending(path: "sessions/\(id)/compress"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(SessionUsage.self, from: data)
    }

    // MARK: Chat

    func sendMessage(sessionId: String, agentId: String = "callie", text: String) async throws -> String {
        var req = URLRequest(url: Self.baseURL.appending(path: "chat/send"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequestBody(sessionId: sessionId, agentId: agentId, message: text, stream: true)
        req.httpBody = try encoder.encode(body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try decoder.decode(RequestHandle.self, from: data).requestId
    }

    func streamResponse(requestId: String) -> AsyncThrowingStream<BridgeEvent, Error> {
        var req = URLRequest(url: Self.baseURL.appending(path: "chat/stream/\(requestId)"))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.timeoutInterval = 300
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (asyncBytes, _) = try await URLSession.shared.bytes(for: req)
                    var parser = SSEParser()
                    var lineBytes = [UInt8]()
                    // Accumulate raw bytes per line, decode as UTF-8 at each newline
                    // to correctly handle multi-byte characters (emoji, etc.).
                    for try await byte in asyncBytes {
                        if byte == UInt8(ascii: "\n") {
                            let line = String(bytes: lineBytes, encoding: .utf8) ?? ""
                            lineBytes.removeAll(keepingCapacity: true)
                            if let event = parser.feed(line) {
                                continuation.yield(event)
                                switch event {
                                case .assistantCompleted, .assistantFailed, .requestCompleted:
                                    continuation.finish()
                                    return
                                default:
                                    break
                                }
                            }
                        } else if byte != UInt8(ascii: "\r") {
                            lineBytes.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelRequest(requestId: String) async {
        var req = URLRequest(url: Self.baseURL.appending(path: "chat/cancel/\(requestId)"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }
}
