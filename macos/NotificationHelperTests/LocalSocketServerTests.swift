import Darwin
import Foundation
import XCTest
@testable import NotificationHelper

final class LocalSocketServerTests: XCTestCase {
    @MainActor
    func testEndpointPathAcceptsTheLastByteAndRejectsOneMore() throws {
        let largestPath = "/" + String(repeating: "x", count: 102)
        XCTAssertEqual(largestPath.utf8.count, 103)
        XCTAssertNoThrow(try LocalSocketServer.validateEndpointPath(largestPath))

        let overlongPath = "/" + String(repeating: "x", count: 103)
        XCTAssertThrowsError(try LocalSocketServer.validateEndpointPath(overlongPath)) { error in
            guard case LocalSocketServerError.endpointTooLong = error else {
                return XCTFail("Expected an endpoint-too-long error")
            }
        }
    }

    @MainActor
    func testStartupPreservesUnexpectedEndpointEntries() throws {
        let regularFile = try SocketTestEndpoint()
        try Data("preserve".utf8).write(to: URL(fileURLWithPath: regularFile.socketPath))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: regularFile.socketPath
        )

        let regularFileServer = try makeServer(endpoint: regularFile) { _ in
            .error(.invalidRequest)
        }
        XCTAssertThrowsError(try regularFileServer.start()) { error in
            guard case LocalSocketServerError.invalidEndpoint = error else {
                return XCTFail("Expected an invalid-endpoint error")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: regularFile.socketPath)),
            Data("preserve".utf8)
        )

        let symlink = try SocketTestEndpoint()
        let target = URL(fileURLWithPath: symlink.directoryPath)
            .appendingPathComponent("target")
        try Data("keep target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: symlink.socketPath,
            withDestinationPath: target.path
        )

        let symlinkServer = try makeServer(endpoint: symlink) { _ in
            .error(.invalidRequest)
        }
        XCTAssertThrowsError(try symlinkServer.start()) { error in
            guard case LocalSocketServerError.invalidEndpoint = error else {
                return XCTFail("Expected an invalid-endpoint error")
            }
        }
        var linkStatus = stat()
        XCTAssertEqual(symlink.socketPath.withCString { lstat($0, &linkStatus) }, 0)
        XCTAssertEqual(linkStatus.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep target".utf8))
    }

    @MainActor
    func testStartupFailureRemovesItsOwnedSocket() throws {
        let testEndpoint = try SocketTestEndpoint()
        let endpoint = try LocalSocketEndpoint(
            path: testEndpoint.socketPath,
            listenOperation: { _, _ in
                errno = EIO
                return -1
            }
        )

        XCTAssertThrowsError(try endpoint.openListener(backlog: 1)) { error in
            guard case LocalSocketServerError.socketOperation(let code) = error,
                  code == EIO
            else {
                return XCTFail("Expected the injected listen failure")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: testEndpoint.socketPath))
    }

    @MainActor
    func testStartupFailurePreservesReplacementEndpointEntry() throws {
        let testEndpoint = try SocketTestEndpoint()
        let replacement = Data("replacement".utf8)
        var replacementError: Error?
        let endpoint = try LocalSocketEndpoint(
            path: testEndpoint.socketPath,
            listenOperation: { _, _ in
                // This operation runs after bind and identity capture. Replace
                // the pathname before returning a controlled startup failure.
                do {
                    try FileManager.default.removeItem(atPath: testEndpoint.socketPath)
                    try replacement.write(
                        to: URL(fileURLWithPath: testEndpoint.socketPath)
                    )
                } catch {
                    replacementError = error
                }
                errno = EIO
                return -1
            }
        )

        XCTAssertThrowsError(try endpoint.openListener(backlog: 1)) { error in
            guard case LocalSocketServerError.socketOperation(let code) = error,
                  code == EIO
            else {
                return XCTFail("Expected the injected listen failure")
            }
        }
        XCTAssertNil(replacementError)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: testEndpoint.socketPath)),
            replacement
        )
        var status = stat()
        XCTAssertEqual(testEndpoint.socketPath.withCString { lstat($0, &status) }, 0)
        XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
    }

    @MainActor
    func testConcurrentStartupLeavesOneLiveEndpointOwner() async throws {
        let endpoint = try SocketTestEndpoint()
        let servers = try (0..<2).map { _ in
            try makeServer(endpoint: endpoint) { _ in .error(.invalidRequest) }
        }

        let attempts = await withTaskGroup(of: StartupAttempt.self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    do {
                        try server.start()
                        return StartupAttempt(index: index, started: true, lockHeld: false)
                    } catch LocalSocketServerError.lockHeld {
                        return StartupAttempt(index: index, started: false, lockHeld: true)
                    } catch {
                        return StartupAttempt(index: index, started: false, lockHeld: false)
                    }
                }
            }
            var results: [StartupAttempt] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(attempts.filter(\.started).count, 1)
        XCTAssertEqual(attempts.filter(\.lockHeld).count, 1)
        let ownerIndex = try XCTUnwrap(attempts.first(where: \.started)?.index)
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpoint.socketPath))

        await stop(servers[1 - ownerIndex])
        await stop(servers[ownerIndex])
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.socketPath))
    }

    @MainActor
    func testMalformedOversizedAndTrailingRequestsNeverReachHandler() async throws {
        let endpoint = try SocketTestEndpoint()
        var handlerCalls = 0
        let server = try makeServer(endpoint: endpoint) { _ in
            handlerCalls += 1
            return .bound(bindingID: "fragmented_binding")
        }
        try server.start()
        defer { server.stop {} }

        let malformed = try NotificationProtocol.encodeFrame(Data("{".utf8))
        let malformedResponse = try await exchange(endpoint: endpoint, bytes: malformed)
        XCTAssertEqual(malformedResponse, .error(.invalidRequest))

        let oversizedResponse = try await exchange(
            endpoint: endpoint,
            bytes: Data([0, 0, 16, 1])
        )
        XCTAssertEqual(oversizedResponse, .error(.requestTooLarge))

        var trailing = try bindFrame()
        trailing.append(0x78)
        let trailingResponse = try await exchange(endpoint: endpoint, bytes: trailing)
        XCTAssertEqual(trailingResponse, .error(.invalidRequest))

        let unsupportedVersion = try NotificationProtocol.encodeFrame(
            Data(#"{"version":2,"type":"bind"}"#.utf8)
        )
        let unsupportedResponse = try await exchange(
            endpoint: endpoint,
            bytes: unsupportedVersion
        )
        XCTAssertEqual(unsupportedResponse, .error(.unsupportedVersion))
        XCTAssertEqual(handlerCalls, 0)

        let fragmentedResponse = try await exchange(
            endpoint: endpoint,
            bytes: bindFrame(),
            fragmented: true
        )
        XCTAssertEqual(fragmentedResponse, .bound(bindingID: "fragmented_binding"))
        XCTAssertEqual(handlerCalls, 1)
        await stop(server)
    }

    @MainActor
    func testStalledAndPrematureRequestsCloseWithoutCallingHandler() async throws {
        let endpoint = try SocketTestEndpoint()
        var configuration = LocalSocketServerConfiguration()
        configuration.workerCount = 1
        configuration.queuedConnectionLimit = 1
        configuration.requestTimeoutNanoseconds = 150_000_000
        var handlerCalls = 0
        let server = try makeServer(endpoint: endpoint, configuration: configuration) { _ in
            handlerCalls += 1
            return .error(.invalidRequest)
        }
        try server.start()
        defer { server.stop {} }

        let stalledHeader = try await performPartialExchange(
            endpointPath: endpoint.socketPath,
            bytes: Data([0]),
            halfClose: false
        )
        XCTAssertTrue(stalledHeader.isEmpty)

        let stalledPayload = try await performPartialExchange(
            endpointPath: endpoint.socketPath,
            bytes: Data([0, 0, 0, 8, 0x7b]),
            halfClose: false
        )
        XCTAssertTrue(stalledPayload.isEmpty)

        let missingHalfClose = try await performPartialExchange(
            endpointPath: endpoint.socketPath,
            bytes: bindFrame(),
            halfClose: false
        )
        XCTAssertTrue(missingHalfClose.isEmpty)

        let prematureResponse = try await performPartialExchange(
            endpointPath: endpoint.socketPath,
            bytes: Data([0]),
            halfClose: true
        )
        XCTAssertTrue(prematureResponse.isEmpty)
        XCTAssertEqual(handlerCalls, 0)
        await stop(server)
    }

    @MainActor
    func testPeerDisconnectDoesNotPreventTheNextRequest() async throws {
        let endpoint = try SocketTestEndpoint()
        let handlerRan = expectation(description: "first handler ran")
        var handlerCalls = 0
        let server = try makeServer(endpoint: endpoint) { _ in
            handlerCalls += 1
            if handlerCalls == 1 {
                handlerRan.fulfill()
            }
            return .bound(bindingID: "test_binding")
        }
        try server.start()
        defer { server.stop {} }

        try await Task.detached {
            let descriptor = try connectSocket(endpoint.socketPath)
            defer { _ = Darwin.close(descriptor) }
            try sendBytes(bindFrame(), to: descriptor)
            // Closing the client supplies the EOF required to validate the
            // request before the server calls its main-actor handler.
        }.value

        await fulfillment(of: [handlerRan], timeout: 5)
        let response = try await exchange(endpoint: endpoint, bytes: bindFrame())
        XCTAssertEqual(response, .bound(bindingID: "test_binding"))
        XCTAssertEqual(handlerCalls, 2)
        await stop(server)
    }

    @MainActor
    func testExpiredQueuedConnectionDoesNotRestartItsDeadlineAndCapacityRecovers() async throws {
        let endpoint = try SocketTestEndpoint()
        var configuration = LocalSocketServerConfiguration()
        configuration.workerCount = 1
        configuration.queuedConnectionLimit = 1
        configuration.backlog = 8
        configuration.requestTimeoutNanoseconds = 250_000_000
        let workerEntered = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        var handlerCalls = 0
        var handlerWaitTimedOut = false
        let server = try makeServer(endpoint: endpoint, configuration: configuration) { _ in
            handlerCalls += 1
            if handlerCalls == 1 {
                workerEntered.signal()
                if releaseWorker.wait(timeout: .now() + .seconds(5)) == .timedOut {
                    handlerWaitTimedOut = true
                }
            }
            return .bound(bindingID: "test_binding")
        }
        try server.start()
        defer { server.stop {} }

        let endpointPath = endpoint.socketPath
        let request = try bindFrame()
        let requestTimeoutNanoseconds = configuration.requestTimeoutNanoseconds
        let scenario = try await Task.detached {
            var workerReleased = false
            defer {
                if !workerReleased {
                    releaseWorker.signal()
                }
            }

            let activeDescriptor = try connectSocket(endpointPath)
            defer { _ = Darwin.close(activeDescriptor) }
            try sendBytes(request, to: activeDescriptor)
            guard Darwin.shutdown(activeDescriptor, SHUT_WR) == 0 else {
                throw SocketTestError.systemCall(errno)
            }
            guard waitForSignal(workerEntered, timeout: .seconds(5)) else {
                throw SocketTestError.synchronizationTimedOut("the first handler")
            }

            // Connect in order while the handler holds the only worker. Once
            // the excess peer sees EOF, the waiting slot is occupied by the
            // second connection and the excess connection was rejected.
            let queuedDescriptor = try connectSocket(endpointPath)
            defer { _ = Darwin.close(queuedDescriptor) }
            try sendBytes(request, to: queuedDescriptor)
            guard Darwin.shutdown(queuedDescriptor, SHUT_WR) == 0 else {
                throw SocketTestError.systemCall(errno)
            }

            let excessDescriptor = try connectSocket(endpointPath)
            defer { _ = Darwin.close(excessDescriptor) }
            try? sendBytes(request, to: excessDescriptor)
            _ = Darwin.shutdown(excessDescriptor, SHUT_WR)
            let excessClosedBeforeRelease = waitForPeerEOF(
                excessDescriptor,
                timeoutNanoseconds: 1_000_000_000
            )
            let queuedRemainedOpenAfterExcessRejection = peerRemainsOpen(
                queuedDescriptor,
                timeoutNanoseconds: 50_000_000
            )

            // The accept loop has handled the excess peer by this point, so
            // the earlier queued peer was accepted. It also stayed open after
            // the excess peer closed. Wait out its request budget before
            // releasing the worker.
            try await Task.sleep(nanoseconds: requestTimeoutNanoseconds + 50_000_000)
            releaseWorker.signal()
            workerReleased = true

            let activeResponse = try readToEOF(activeDescriptor)
            let queuedResponse = try readToEOF(queuedDescriptor)
            let laterResponse = try await performExchange(
                endpointPath: endpointPath,
                bytes: request
            )
            return (
                activeResponse: activeResponse,
                queuedResponse: queuedResponse,
                laterResponse: laterResponse,
                excessClosedBeforeRelease: excessClosedBeforeRelease,
                queuedRemainedOpenAfterExcessRejection: queuedRemainedOpenAfterExcessRejection
            )
        }.value

        XCTAssertFalse(handlerWaitTimedOut)
        XCTAssertTrue(
            scenario.excessClosedBeforeRelease,
            "The excess connection must close before worker release"
        )
        XCTAssertTrue(
            scenario.queuedRemainedOpenAfterExcessRejection,
            "The queued connection must remain open after capacity rejection"
        )
        XCTAssertEqual(
            try NotificationProtocol.decodeResponse(
                NotificationProtocol.decodeFrame(scenario.activeResponse)
            ),
            .bound(bindingID: "test_binding")
        )
        XCTAssertTrue(
            scenario.queuedResponse.isEmpty,
            "The queued request must expire before reaching the handler"
        )
        XCTAssertEqual(
            try NotificationProtocol.decodeResponse(
                NotificationProtocol.decodeFrame(scenario.laterResponse)
            ),
            .bound(bindingID: "test_binding")
        )
        XCTAssertEqual(handlerCalls, 2, "Only the active request and later request should reach the handler")
        await stop(server)
    }

    @MainActor
    func testExpiredResponseBudgetClosesConnection() async throws {
        let endpoint = try SocketTestEndpoint()
        var configuration = LocalSocketServerConfiguration()
        configuration.responseTimeoutNanoseconds = 0
        var handlerCalls = 0
        let server = try makeServer(endpoint: endpoint, configuration: configuration) { _ in
            handlerCalls += 1
            return .bound(bindingID: "test_binding")
        }
        try server.start()
        defer { server.stop {} }

        let responseBytes = try await performExchange(
            endpointPath: endpoint.socketPath,
            bytes: bindFrame()
        )
        XCTAssertTrue(responseBytes.isEmpty)
        XCTAssertEqual(handlerCalls, 1)
        await stop(server)
    }

    /// Checks that a response waiting for socket space expires and closes its connection.
    ///
    /// Known setup bytes fill the outgoing buffer before the bind request. The
    /// peer stays open and unread until the worker returns, so disconnect cannot
    /// end the write early.
    @MainActor
    func testBlockedResponseWriteExpiresAtItsDeadline() async throws {
        let responseBudget: UInt64 = 150_000_000
        var handlerCalls = 0
        var responseReadyAt: UInt64?
        let handler: LocalSocketServer.RequestHandler = { _ in
            handlerCalls += 1
            responseReadyAt = DispatchTime.now().uptimeNanoseconds
            return .bound(bindingID: "test_binding")
        }

        let exchange = try await Task.detached {
            try performBlockedResponseExchange(
                responseTimeoutNanoseconds: responseBudget,
                handler: handler
            )
        }.value

        XCTAssertEqual(handlerCalls, 1)
        let readyAt = try XCTUnwrap(responseReadyAt)
        let elapsed = exchange.finishedAt - readyAt
        XCTAssertGreaterThanOrEqual(elapsed, responseBudget)
        XCTAssertLessThan(elapsed, 2_000_000_000, "Response waiting must remain bounded")
        XCTAssertFalse(exchange.prefilledBytes.isEmpty)
        XCTAssertEqual(
            exchange.receivedBytes,
            exchange.prefilledBytes,
            "The peer must receive only setup bytes followed by EOF, with no response"
        )
    }

    @MainActor
    private func makeServer(
        endpoint: SocketTestEndpoint,
        configuration: LocalSocketServerConfiguration = .init(),
        handler: @escaping LocalSocketServer.RequestHandler
    ) throws -> LocalSocketServer {
        try LocalSocketServer(
            endpointPath: endpoint.socketPath,
            configuration: configuration,
            handler: handler
        )
    }

    @MainActor
    private func exchange(
        endpoint: SocketTestEndpoint,
        bytes: Data,
        fragmented: Bool = false
    ) async throws -> NotificationProtocol.Response {
        try NotificationProtocol.decodeResponse(
            NotificationProtocol.decodeFrame(
                await performExchange(
                    endpointPath: endpoint.socketPath,
                    bytes: bytes,
                    fragmented: fragmented
                )
            )
        )
    }

    @MainActor
    private func stop(_ server: LocalSocketServer) async {
        await withCheckedContinuation { continuation in
            server.stop {
                continuation.resume()
            }
        }
    }
}

private final class SocketTestEndpoint: @unchecked Sendable {
    let directoryPath: String
    let socketPath: String

    init() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("zed-notify-socket-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        directoryPath = directory.path
        socketPath = directory.appendingPathComponent("helper.sock").path
    }

    deinit {
        remove()
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directoryPath)
    }
}

private struct StartupAttempt: Sendable {
    let index: Int
    let started: Bool
    let lockHeld: Bool
}

private enum SocketTestError: LocalizedError {
    case endpointPathTooLong
    case systemCall(Int32)
    case prematureEOF
    case synchronizationTimedOut(String)
    case outgoingBufferDidNotFill

    var errorDescription: String? {
        switch self {
        case .endpointPathTooLong:
            "The test endpoint path exceeded the Unix socket path limit"
        case .systemCall(let code):
            "The test socket system call failed with errno \(code)"
        case .prematureEOF:
            "The test socket closed before its frame completed"
        case .synchronizationTimedOut(let event):
            "The test timed out waiting for \(event)"
        case .outgoingBufferDidNotFill:
            "The test socket did not fill within the 16 KiB setup cap and one-second deadline"
        }
    }
}

/// Runs a real connection exchange whose response has no outgoing buffer space.
///
/// Call off the main actor so its handler can run during the worker wait. Setup
/// requests a 4 KiB send buffer and writes at most 16 KiB of synthetic data.
/// `serve` owns the server descriptor after dispatch; this fixture owns the peer.
private func performBlockedResponseExchange(
    responseTimeoutNanoseconds: UInt64,
    handler: @escaping LocalSocketServer.RequestHandler
) throws -> (prefilledBytes: Data, receivedBytes: Data, finishedAt: UInt64) {
    var descriptors: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw SocketTestError.systemCall(errno)
    }
    let serverDescriptor = descriptors[0]
    let peerDescriptor = descriptors[1]
    var serverOwnsDescriptor = false
    defer {
        if !serverOwnsDescriptor {
            _ = Darwin.close(serverDescriptor)
        }
        _ = Darwin.close(peerDescriptor)
    }

    for descriptor in descriptors {
        guard LocalSocketOperations.setNonblocking(descriptor),
              LocalSocketOperations.setNoSigPipe(descriptor)
        else {
            throw SocketTestError.systemCall(errno)
        }
    }
    var sendBufferSize: Int32 = 4 * 1024
    guard Darwin.setsockopt(
        serverDescriptor,
        SOL_SOCKET,
        SO_SNDBUF,
        &sendBufferSize,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        throw SocketTestError.systemCall(errno)
    }
    var optionLength = socklen_t(MemoryLayout<Int32>.size)
    guard Darwin.getsockopt(
        serverDescriptor,
        SOL_SOCKET,
        SO_SNDBUF,
        &sendBufferSize,
        &optionLength
    ) == 0 else {
        throw SocketTestError.systemCall(errno)
    }
    guard sendBufferSize > 0, sendBufferSize <= 16 * 1024 else {
        throw SocketTestError.outgoingBufferDidNotFill
    }

    let prefilledBytes = try fillOutgoingBuffer(serverDescriptor)
    // The two socket directions have separate capacity. Filling server-to-peer
    // leaves peer-to-server available for this valid request and its EOF.
    try sendBytes(bindFrame(), to: peerDescriptor)
    guard Darwin.shutdown(peerDescriptor, SHUT_WR) == 0 else {
        throw SocketTestError.systemCall(errno)
    }

    var configuration = LocalSocketServerConfiguration()
    configuration.responseTimeoutNanoseconds = responseTimeoutNanoseconds
    let responseConfiguration = configuration
    let connection = LocalSocketConnection(
        descriptor: serverDescriptor,
        acceptedAt: DispatchTime.now().uptimeNanoseconds
    )
    let finished = DispatchSemaphore(value: 0)
    serverOwnsDescriptor = true
    DispatchQueue.global(qos: .userInitiated).async {
        connection.serve(configuration: responseConfiguration, handler: handler)
        finished.signal()
    }
    guard waitForSignal(finished, timeout: .seconds(2)) else {
        // A lost write deadline must fail without leaving a worker behind.
        // Shut down the peer to release the socket wait before fixture cleanup.
        _ = Darwin.shutdown(peerDescriptor, SHUT_RDWR)
        guard waitForSignal(finished, timeout: .seconds(2)) else {
            throw SocketTestError.synchronizationTimedOut("blocked-write worker cleanup")
        }
        throw SocketTestError.synchronizationTimedOut("the response deadline")
    }
    let finishedAt = DispatchTime.now().uptimeNanoseconds
    // serve has returned and closed its socket. Draining cannot make the
    // response write succeed because no worker remains to send response bytes.
    return (prefilledBytes, try readToEOF(peerDescriptor), finishedAt)
}

/// Fills a nonblocking socket until even a one-byte send would have to wait.
///
/// Returns the exact synthetic bytes sent so the caller can distinguish them
/// from a later protocol response. Setup stops at 16 KiB or one second.
private func fillOutgoingBuffer(_ descriptor: Int32) throws -> Data {
    let byteLimit = 16 * 1024
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    let bytes = [UInt8](repeating: 0x5a, count: 512)
    var prefilled = Data()
    var sendSize = bytes.count
    while prefilled.count < byteLimit,
          DispatchTime.now().uptimeNanoseconds < deadline {
        let count = min(sendSize, byteLimit - prefilled.count)
        let result = bytes.withUnsafeBytes {
            Darwin.send(descriptor, $0.baseAddress!, count, 0)
        }
        if result > 0 {
            prefilled.append(contentsOf: bytes.prefix(result))
        } else if result < 0 && errno == EINTR {
            continue
        } else if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            if count == 1 {
                return prefilled
            }
            // A larger send can fail while a small response still fits.
            sendSize = 1
        } else {
            throw SocketTestError.systemCall(result == 0 ? EPIPE : errno)
        }
    }
    throw SocketTestError.outgoingBufferDidNotFill
}

private func bindFrame() throws -> Data {
    try NotificationProtocol.encodeFrame(
        NotificationProtocol.encodeRequest(.bind)
    )
}

private func connectSocket(_ path: String) throws -> Int32 {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8) + [0]
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= pathCapacity else {
        throw SocketTestError.endpointPathTooLong
    }
    let pathOffset = MemoryLayout<sockaddr_un>.size - pathCapacity
    address.sun_len = UInt8(pathOffset + pathBytes.count)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
        for (index, byte) in pathBytes.enumerated() {
            bytes[index] = byte
        }
    }

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw SocketTestError.systemCall(errno)
    }
    var noSigPipe: Int32 = 1
    guard Darwin.setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        let error = errno
        _ = Darwin.close(descriptor)
        throw SocketTestError.systemCall(error)
    }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = Darwin.setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )

    let length = socklen_t(pathOffset + pathBytes.count)
    let result = withUnsafePointer(to: &address) { pointer in
        Darwin.connect(
            descriptor,
            UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self),
            length
        )
    }
    guard result == 0 else {
        let error = errno
        _ = Darwin.close(descriptor)
        throw SocketTestError.systemCall(error)
    }
    return descriptor
}

private func sendBytes(
    _ data: Data,
    to descriptor: Int32,
    fragmented: Bool = false
) throws {
    var offset = 0
    try data.withUnsafeBytes { bytes in
        while offset < bytes.count {
            let count = min(fragmented ? 1 : bytes.count, bytes.count - offset)
            let result = Darwin.send(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                count,
                0
            )
            if result > 0 {
                offset += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                throw SocketTestError.systemCall(result == 0 ? EPIPE : errno)
            }
        }
    }
}

private func readToEOF(_ descriptor: Int32) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 512)
    while true {
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if count == 0 {
            return result
        }
        if count > 0 {
            result.append(contentsOf: buffer.prefix(count))
        } else if errno != EINTR {
            throw SocketTestError.systemCall(errno)
        }
    }
}

private func waitForPeerEOF(_ descriptor: Int32, timeoutNanoseconds: UInt64) -> Bool {
    let milliseconds = Int32(min((timeoutNanoseconds + 999_999) / 1_000_000, UInt64(Int32.max)))
    var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let pollResult = withUnsafeMutablePointer(to: &readiness) {
        Darwin.poll($0, 1, milliseconds)
    }
    guard pollResult > 0 else {
        return false
    }

    var byte: UInt8 = 0
    return Darwin.recv(descriptor, &byte, 1, MSG_DONTWAIT) == 0
}

private func peerRemainsOpen(_ descriptor: Int32, timeoutNanoseconds: UInt64) -> Bool {
    let milliseconds = Int32(min((timeoutNanoseconds + 999_999) / 1_000_000, UInt64(Int32.max)))
    var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let pollResult = withUnsafeMutablePointer(to: &readiness) {
        Darwin.poll($0, 1, milliseconds)
    }
    return pollResult == 0
}

private func waitForSignal(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval
) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

private func performExchange(
    endpointPath: String,
    bytes: Data,
    fragmented: Bool = false
) async throws -> Data {
    try await Task.detached {
        let descriptor = try connectSocket(endpointPath)
        defer { _ = Darwin.close(descriptor) }
        try sendBytes(bytes, to: descriptor, fragmented: fragmented)
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
            throw SocketTestError.systemCall(errno)
        }
        return try readToEOF(descriptor)
    }.value
}

private func performPartialExchange(
    endpointPath: String,
    bytes: Data,
    halfClose: Bool
) async throws -> Data {
    try await Task.detached {
        let descriptor = try connectSocket(endpointPath)
        defer { _ = Darwin.close(descriptor) }
        try sendBytes(bytes, to: descriptor)
        if halfClose {
            guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
                throw SocketTestError.systemCall(errno)
            }
        }
        return try readToEOF(descriptor)
    }.value
}
