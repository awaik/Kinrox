import AppKit
import Foundation
import Network

@MainActor
final class SpotifySpikeLoopback {
    private let listener: NWListener
    private let state: String
    private var pending: CheckedContinuation<String, any Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [NWConnection] = []
    private var opened = false

    init(state: String) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43821)
        listener = try NWListener(using: parameters)
    }

    func receive(authorizationURL: URL) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        switch status {
                        case .ready:
                            guard !self.opened else { return }
                            self.opened = true
                            if !NSWorkspace.shared.open(authorizationURL) {
                                self.finish(.failure(SpotifySpikeFailure.authentication))
                            }
                        case .failed:
                            self.finish(.failure(SpotifySpikeFailure.authentication))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: .main)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.finish(.failure(SpotifySpikeFailure.timeout))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8, pending != nil else {
            connection.cancel()
            return
        }
        connections.append(connection)
        connection.start(queue: .main)
        read(connection, buffered: Data())
    }

    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                let bytes = buffered + (data ?? Data())
                guard bytes.count <= 8192, error == nil else {
                    connection.cancel()
                    return
                }
                if let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n")
                {
                    self.respond(connection, request: request)
                } else if !complete {
                    self.read(connection, buffered: bytes)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let line = request.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard line.count == 3, line[0] == "GET",
            let url = URLComponents(string: "http://127.0.0.1:43821" + String(line[1])),
            url.path == "/callback",
            url.queryItems?.filter({ $0.name == "state" }).count == 1,
            url.queryItems?.first(where: { $0.name == "state" })?.value == state
        else {
            send(connection, status: "400 Bad Request", body: "Invalid callback.")
            return
        }
        if url.queryItems?.contains(where: { $0.name == "error" }) == true {
            send(connection, status: "200 OK", body: "Authorization declined.")
            finish(.failure(SpotifySpikeFailure.authentication))
            return
        }
        guard url.queryItems?.filter({ $0.name == "code" }).count == 1,
            let code = url.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else {
            send(connection, status: "400 Bad Request", body: "Invalid callback.")
            return
        }
        send(connection, status: "200 OK", body: "Connected. Return to Kinrox.", code: code)
    }

    private func send(_ connection: NWConnection, status: String, body: String, code: String? = nil)
    {
        let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                Task { @MainActor in
                    self?.connections.removeAll { $0 === connection }
                    if let code { self?.finish(.success(code)) }
                }
            })
    }

    private func finish(_ result: Result<String, any Error>) {
        let continuation = pending
        pending = nil
        timeout?.cancel()
        timeout = nil
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
        continuation?.resume(with: result)
    }
}
