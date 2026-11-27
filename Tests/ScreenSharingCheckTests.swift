import Network
import XCTest
@testable import DeskLink

final class ScreenSharingCheckTests: XCTestCase {
    func testRecognizesStandardAndAppleGreetingsWithoutSendingData() async throws {
        for greeting in ["RFB 003.008\n", "RFB 003.889\n"] {
            let connectionClosed = XCTestExpectation(description: "The client closed without responding")
            let fixture = try Listener { connection in
                connection.send(content: Data(greeting.utf8), completion: .idempotent)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { bytes, _, _, _ in
                    XCTAssertTrue(bytes?.isEmpty ?? true)
                    connectionClosed.fulfill()
                    connection.cancel()
                }
            }
            let endpoint = try await fixture.endpoint()
            let result = await ScreenSharingCheck.check(endpoint)
            XCTAssertEqual(result, .responding)
            await fulfillment(of: [connectionClosed], timeout: 2)
        }
    }

    func testOpenPortWithDifferentServiceDoesNotReportScreenSharing() async throws {
        let fixture = try Listener { connection in
            connection.send(content: Data("HTTP/1.1 200 OK\r\n".utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        let endpoint = try await fixture.endpoint()
        let result = await ScreenSharingCheck.check(endpoint)
        XCTAssertEqual(result, .unexpectedResponse)
    }

    func testSilentPortTimesOut() async throws {
        let fixture = try Listener { connection in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { _, _, _, _ in connection.cancel() }
        }
        let endpoint = try await fixture.endpoint()
        let result = await ScreenSharingCheck.check(endpoint, timeout: .milliseconds(120))
        XCTAssertEqual(result, .timedOut)
    }

    func testCancellingAnAcceptedConnectionClosesIt() async throws {
        let accepted = XCTestExpectation(description: "Accepted connection")
        let closed = XCTestExpectation(description: "Cancelled the connection")
        let fixture = try Listener { connection in
            accepted.fulfill()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { _, _, _, _ in
                closed.fulfill()
                connection.cancel()
            }
        }
        let endpoint = try await fixture.endpoint()
        let check = Task { await ScreenSharingCheck.check(endpoint, timeout: .seconds(10)) }
        await fulfillment(of: [accepted], timeout: 2)
        check.cancel()
        let result = await check.value
        XCTAssertNil(result)
        await fulfillment(of: [closed], timeout: 2)
    }
}

private final class Listener {
    private let listener: NWListener
    private let ports: AsyncStream<Result<NWEndpoint.Port, NWError>>

    init(handle: @escaping @Sendable (NWConnection) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let (ports, output) = AsyncStream.makeStream(of: Result<NWEndpoint.Port, NWError>.self,
                                                     bufferingPolicy: .bufferingOldest(1))
        self.ports = ports
        let queue = DispatchQueue(label: "ScreenSharingCheckTests.Listener")
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                if let port = listener?.port { output.yield(.success(port)) }
                output.finish()
            case .failed(let error):
                output.yield(.failure(error))
                output.finish()
            case .cancelled:
                output.finish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            handle(connection)
        }
        listener.start(queue: queue)
    }

    deinit { listener.cancel() }

    func endpoint() async throws -> Endpoint {
        var iterator = ports.makeAsyncIterator()
        let result = await iterator.next()
        switch try XCTUnwrap(result) {
        case .success(let port): return try Endpoint(address: "127.0.0.1", defaultPort: port.rawValue)
        case .failure(.posix(.EPERM)), .failure(.posix(.EACCES)):
            throw XCTSkip("The test host cannot open a loopback listener.")
        case .failure(let error): throw error
        }
    }
}
