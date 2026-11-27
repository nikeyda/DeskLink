import Foundation
import Network

enum ScreenSharingCheck {
    enum Outcome: Equatable, Sendable {
        case responding
        case unexpectedResponse
        case unavailable
        case timedOut
    }

    static func check(_ endpoint: Endpoint, timeout: Duration = .seconds(4)) async -> Outcome? {
        guard !Task.isCancelled else { return nil }
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return .unavailable }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        let (outcomes, output) = AsyncStream.makeStream(of: Outcome.self, bufferingPolicy: .bufferingOldest(1))

        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                // The server speaks first. Stop before sending any RFB data.
                connection?.receive(minimumIncompleteLength: 12, maximumLength: 12) { data, _, _, error in
                    let outcome = data.map(classify) ?? .unavailable
                    output.yield(error == nil ? outcome : .unavailable)
                    output.finish()
                }
            case .failed, .waiting(.posix(.ECONNREFUSED)):
                output.yield(.unavailable)
                output.finish()
            default:
                break
            }
        }

        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            output.yield(.timedOut)
            output.finish()
        }
        defer {
            deadline.cancel()
            output.finish()
            connection.cancel()
        }

        connection.start(queue: .global(qos: .utility))
        var iterator = outcomes.makeAsyncIterator()
        let outcome = await iterator.next()
        return Task.isCancelled ? nil : outcome
    }

    private static func classify(_ greeting: Data) -> Outcome {
        let bytes = Array(greeting)
        guard bytes.count == 12, bytes.starts(with: [82, 70, 66, 32]), bytes[7] == 46, bytes[11] == 10,
              bytes[4...6].allSatisfy((48...57).contains), bytes[8...10].allSatisfy((48...57).contains) else {
            return .unexpectedResponse
        }
        return .responding
    }
}
