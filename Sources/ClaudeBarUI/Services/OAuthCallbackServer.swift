import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 used as the OAuth redirect target.
/// Serves a single "you can close this tab" page and hands the callback's
/// query parameters back to the caller, then tears itself down.
final class OAuthCallbackServer {
    /// All NWListener/NWConnection callbacks run here, so `finished` needs no
    /// extra locking.
    private let queue = DispatchQueue(label: "com.claudebar.oauth-callback")
    private var finished = false

    /// Pull the query parameters out of an HTTP request head. Returns nil for
    /// anything that isn't a GET on /callback (browsers also ask for favicons).
    static func parseCallback(requestHead: String) -> [String: String]? {
        guard let line = requestHead.split(separator: "\r\n", omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        guard let components = URLComponents(string: "http://localhost\(parts[1])"),
              components.path == "/callback" else { return nil }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name] = item.value ?? "" }
        return params
    }

    private static let responsePage = """
    HTTP/1.1 200 OK\r
    Content-Type: text/html; charset=utf-8\r
    Connection: close\r
    \r
    <html><body style="font-family:-apple-system;text-align:center;padding-top:80px">\
    <h2>Signed in to ClaudeBar</h2><p>You can close this tab.</p></body></html>
    """

    /// Binds an OS-assigned ephemeral port (matching Claude Code CLI's own
    /// `.listen(0, "127.0.0.1")`) — a fixed port got rejected server-side
    /// with "Invalid request format" — then waits for the browser redirect.
    ///
    /// `onPortBound` fires as soon as the port is known, before the browser
    /// has been opened, so the caller can build the authorize URL's
    /// `redirect_uri`. Both `stateUpdateHandler` and `newConnectionHandler`
    /// must be set before `start(queue:)` is called, or the listener fails
    /// immediately with EINVAL.
    func waitForCallback(
        timeout: TimeInterval = 300,
        onPortBound: @escaping (UInt16) -> Void
    ) async throws -> [String: String] {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            throw OAuthError.listenerFailed(error.localizedDescription)
        }
        defer { listener.cancel() }

        return try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await self.accept(listener: listener, onPortBound: onPortBound) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw OAuthError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func accept(
        listener: NWListener,
        onPortBound: @escaping (UInt16) -> Void
    ) async throws -> [String: String] {
        // The cancellation handler cancels the listener, whose `.cancelled`
        // state then resumes the continuation — without it, the timeout path
        // would block forever in the task group's implicit await of this task.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                func finish(_ result: Result<[String: String], Error>) {
                    guard !self.finished else { return }
                    self.finished = true
                    continuation.resume(with: result)
                }

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue { onPortBound(port) }
                    case .failed(let error):
                        finish(.failure(OAuthError.listenerFailed(error.localizedDescription)))
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { connection in
                    connection.start(queue: self.queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                        if let error {
                            finish(.failure(error))
                            connection.cancel()
                            return
                        }
                        let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        connection.send(
                            content: Data(Self.responsePage.utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        if let params = Self.parseCallback(requestHead: head) {
                            finish(.success(params))
                        }
                    }
                }

                listener.start(queue: queue)
            }
        } onCancel: {
            listener.cancel()
        }
    }
}
