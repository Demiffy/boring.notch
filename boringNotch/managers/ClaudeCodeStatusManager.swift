//
//  ClaudeCodeStatusManager.swift
//  boringNotch
//
//  Mirrors Claude Code sessions into the notch. Claude Code hooks POST their
//  stdin payload to a loopback port; we only read the event name, session id
//  and cwd, so the hook command can stay a one-line `curl`.
//

import Foundation
import Network

enum ClaudeSessionState: Equatable {
    case working
    case waiting
    case done
    /// The turn ended on an API error (usage limit, auth, overload) instead of finishing.
    case failed
}

struct ClaudeSession: Identifiable, Equatable {
    let id: String
    var project: String
    var state: ClaudeSessionState
    var updatedAt: Date
    /// When the current turn began (the prompt was sent).
    var startedAt: Date
}

@MainActor
final class ClaudeCodeStatusManager: ObservableObject {
    static let shared = ClaudeCodeStatusManager()
    static let port: UInt16 = 47483

    @Published private(set) var sessions: [String: ClaudeSession] = [:]

    /// How long a finished session keeps its checkmark before dropping out.
    private let doneDuration: TimeInterval = 10
    /// A failed turn stays a little longer so it isn't missed.
    private let failedDuration: TimeInterval = 30
    /// A session that stops reporting (crash, killed terminal) is dropped
    /// after this long so the spinner can't get stuck.
    private let staleAfter: TimeInterval = 15 * 60
    private let maxBodySize = 256 * 1024

    private var listener: NWListener?
    private var sweepTask: Task<Void, Never>?

    private init() {}

    /// What the closed notch shows: the most urgent state across sessions.
    var overallState: ClaudeSessionState? {
        let states = sessions.values.map(\.state)
        if states.contains(.waiting) { return .waiting }
        if states.contains(.failed) { return .failed }
        if states.contains(.working) { return .working }
        return states.isEmpty ? nil : .done
    }

    var workingCount: Int { sessions.values.filter { $0.state == .working }.count }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: parameters, on: port) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener

        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.sweep()
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sweepTask?.cancel()
        sweepTask = nil
        sessions.removeAll()
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }

                if let body = Self.completeBody(in: buffer) {
                    self.handle(body)
                    self.respond(on: connection, status: "204 No Content")
                } else if buffer.count > self.maxBodySize || isComplete || error != nil {
                    self.respond(on: connection, status: "400 Bad Request")
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(on connection: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Returns the request body once headers and `Content-Length` bytes have
    /// all arrived, nil while the request is still incomplete.
    nonisolated static func completeBody(in buffer: Data) -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let length = headers
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) }
            ?? 0
        let body = buffer[headerEnd.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    // MARK: - Hook events

    private func handle(_ body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let event = json["hook_event_name"] as? String,
              let sessionID = json["session_id"] as? String else { return }
        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? sessions[sessionID]?.project
            ?? "Claude"

        guard let state = Self.state(
            for: event,
            notificationType: json["notification_type"] as? String,
            message: json["message"] as? String
        ) else {
            if event == "SessionEnd" { sessions[sessionID] = nil }
            return
        }
        let now = Date()
        let previous = sessions[sessionID]
        // A new turn starts when work begins after the last one ended.
        let continuing = previous.map { $0.state == .working || $0.state == .waiting } ?? false
        sessions[sessionID] = ClaudeSession(
            id: sessionID,
            project: project,
            state: state,
            updatedAt: now,
            startedAt: continuing ? previous!.startedAt : now
        )
    }

    /// Maps a hook event to a session state; nil means "don't change state".
    nonisolated static func state(for event: String, notificationType: String?, message: String?) -> ClaudeSessionState? {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .working
        case "Stop":
            return .done
        case "StopFailure":
            return .failed
        case "Notification":
            // The idle reminder ("waiting for your input") fires a minute
            // after every finished turn; treating it as "needs you" would
            // leave a permanent badge for every session you walked away from.
            if notificationType == "idle_prompt" { return nil }
            if message?.localizedCaseInsensitiveContains("waiting for your input") == true { return nil }
            return .waiting
        default:
            return nil
        }
    }

    private func sweep() {
        let now = Date()
        let expired = sessions.values.filter { session in
            let age = now.timeIntervalSince(session.updatedAt)
            switch session.state {
            case .done: return age > doneDuration
            case .failed: return age > failedDuration
            case .working, .waiting: return age > staleAfter
            }
        }
        for session in expired { sessions[session.id] = nil }
    }
}
