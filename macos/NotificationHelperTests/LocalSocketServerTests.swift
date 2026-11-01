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
        var handlerCalls = 0
        let server = try makeServer(endpoint: endpoint) { _ in
            handlerCalls += 1
            return .bound(bindingID: "test_binding")
        }
        try server.start()
        defer { server.stop {} }

        try await Task.detached {
            let descriptor = try connectSocket(endpoint.socketPath)
            defer { _ = Darwin.close(descriptor) }
            try sendBytes(bindFrame(), to: descriptor)
            guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
                throw SocketTestError.systemCall(errno)
            }
        }.value

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
        configuration.requestTimeoutNanoseconds = 160_000_000
        var handlerCalls = 0
        let server = try makeServer(endpoint: endpoint, configuration: configuration) { _ in
            handlerCalls += 1
            if handlerCalls == 1 {
                // Keep the sole worker occupied long enough for a queued
                // connection's accept-time deadline to expire.
                Thread.sleep(forTimeInterval: 0.25)
            }
            return .bound(bindingID: "test_binding")
        }
        try server.start()
        defer { server.stop {} }

        let activeConnection = Task.detached {
            try await performExchange(
                endpointPath: endpoint.socketPath,
                bytes: bindFrame()
            )
        }
        let queuedConnection = Task.detached {
            try await Task.sleep(nanoseconds: 30_000_000)
            return try await performExchange(
                endpointPath: endpoint.socketPath,
                bytes: bindFrame()
            )
        }
        let excessConnection = Task.detached {
            try await Task.sleep(nanoseconds: 60_000_000)
            let descriptor = try connectSocket(endpoint.socketPath)
            defer { _ = Darwin.close(descriptor) }
            // Capacity rejection can close the accepted socket before this
            // client finishes writing its request.
            try? sendBytes(bindFrame(), to: descriptor)
            _ = Darwin.shutdown(descriptor, SHUT_WR)
            return try readToEOF(descriptor)
        }

        let activeResponse = try await activeConnection.value
        let queuedResponse = try await queuedConnection.value
        let excessResponse = try await excessConnection.value
        XCTAssertEqual(
            try NotificationProtocol.decodeResponse(
                NotificationProtocol.decodeFrame(activeResponse)
            ),
            .bound(bindingID: "test_binding")
        )
        XCTAssertTrue(queuedResponse.isEmpty)
        XCTAssertTrue(excessResponse.isEmpty)
        XCTAssertEqual(handlerCalls, 1)

        let laterResponse = try await exchange(endpoint: endpoint, bytes: bindFrame())
        XCTAssertEqual(laterResponse, .bound(bindingID: "test_binding"))
        XCTAssertEqual(handlerCalls, 2)
        await stop(server)
    }

    @MainActor
    func testResponseDeadlineClosesOnlyTheCurrentConnection() async throws {
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

    var errorDescription: String? {
        switch self {
        case .endpointPathTooLong:
            "The test endpoint path exceeded the Unix socket path limit"
        case .systemCall(let code):
            "The test socket system call failed with errno \(code)"
        case .prematureEOF:
            "The test socket closed before its frame completed"
        }
    }
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
