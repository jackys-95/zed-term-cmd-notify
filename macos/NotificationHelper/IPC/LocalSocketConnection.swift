import Darwin
import Foundation

/// Serves one framed request and response on an accepted connection.
///
/// The server owns the descriptor while queued. A worker calls `serve` once,
/// which closes the descriptor on return. The acceptance time travels with the
/// connection so queue time counts toward the request deadline.
struct LocalSocketConnection {
    let descriptor: Int32
    let acceptedAt: UInt64

    /// Reads and validates a request, calls its handler, and sends the response.
    ///
    /// Call from a worker thread: the main-actor handoff waits for the handler.
    /// A disconnected client can leave the handler's outcome uncertain.
    func serve(
        configuration: LocalSocketServerConfiguration,
        handler: @escaping LocalSocketServer.RequestHandler
    ) {
        defer { _ = Darwin.close(descriptor) }

        let requestDeadline = acceptedAt &+ configuration.requestTimeoutNanoseconds
        guard DispatchTime.now().uptimeNanoseconds < requestDeadline else {
            return
        }

        let payload: Data
        do {
            payload = try readRequestPayload(deadline: requestDeadline)
        } catch let failure as NotificationProtocolFailure {
            try? writeResponse(
                response(for: failure),
                timeoutNanoseconds: configuration.responseTimeoutNanoseconds
            )
            return
        } catch {
            return
        }

        let request: NotificationProtocol.Request
        do {
            request = try NotificationProtocol.decodeRequest(payload)
        } catch let failure as NotificationProtocolFailure {
            try? writeResponse(
                response(for: failure),
                timeoutNanoseconds: configuration.responseTimeoutNanoseconds
            )
            return
        } catch {
            try? writeResponse(
                .error(.invalidRequest),
                timeoutNanoseconds: configuration.responseTimeoutNanoseconds
            )
            return
        }
        let response = invokeHandler(handler, for: request)

        do {
            try writeResponse(response, timeoutNanoseconds: configuration.responseTimeoutNanoseconds)
        } catch {
            // A peer disconnect or write timeout is isolated to this connection.
        }
    }

    private func response(for failure: NotificationProtocolFailure) -> NotificationProtocol.Response {
        switch failure {
        case .unsupportedVersion:
            .error(.unsupportedVersion)
        case .frameTooLarge:
            .error(.requestTooLarge)
        case .emptyFrame, .incompleteFrame, .trailingData, .invalidRequest, .invalidBinding,
             .invalidResponse:
            .error(.invalidRequest)
        }
    }

    private func invokeHandler(
        _ handler: @escaping LocalSocketServer.RequestHandler,
        for request: NotificationProtocol.Request
    ) -> NotificationProtocol.Response {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResponseBox()
        Task { @MainActor in
            result.store(handler(request))
            semaphore.signal()
        }
        // The worker waits here; the main actor remains free to execute the task.
        semaphore.wait()
        return result.load() ?? .error(.invalidRequest)
    }

    private func readRequestPayload(deadline: UInt64) throws -> Data {
        var header = [UInt8](repeating: 0, count: 4)
        try readExactly(into: &header, deadline: deadline)
        let payloadLength = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard payloadLength > 0 else {
            throw NotificationProtocolFailure.emptyFrame
        }
        guard payloadLength <= NotificationProtocol.maxFrameBytes else {
            throw NotificationProtocolFailure.frameTooLarge
        }

        var payload = [UInt8](repeating: 0, count: Int(payloadLength))
        try readExactly(into: &payload, deadline: deadline)

        // For a declared three-byte payload, all three bytes followed by EOF
        // complete the request. A fourth byte makes it trailing data. Withheld
        // EOF keeps waiting under the same deadline used for the header.
        var extraByte: [UInt8] = [0]
        while true {
            try ensureBeforeDeadline(deadline)
            switch receive(into: &extraByte, count: 1) {
            case .bytes(let count) where count > 0:
                throw NotificationProtocolFailure.trailingData
            case .bytes:
                return Data(payload)
            case .wouldBlock:
                try waitUntilReady(events: Int16(POLLIN), deadline: deadline)
            case .interrupted:
                continue
            case .failed(let error):
                throw LocalSocketServerError.socketOperation(error)
            }
        }
    }

    private func readExactly(
        into bytes: inout [UInt8],
        deadline: UInt64
    ) throws {
        var offset = 0
        while offset < bytes.count {
            try ensureBeforeDeadline(deadline)
            switch receive(
                into: &bytes,
                offset: offset,
                count: bytes.count - offset
            ) {
            case .bytes(let count) where count > 0:
                offset += count
            case .bytes:
                throw LocalSocketServerError.incompleteRequest
            case .wouldBlock:
                try waitUntilReady(events: Int16(POLLIN), deadline: deadline)
            case .interrupted:
                continue
            case .failed(let error):
                throw LocalSocketServerError.socketOperation(error)
            }
        }
    }

    private enum ReceiveResult {
        case bytes(Int)
        case wouldBlock
        case interrupted
        case failed(Int32)
    }

    private func receive(
        into bytes: inout [UInt8],
        offset: Int = 0,
        count: Int
    ) -> ReceiveResult {
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            Darwin.recv(
                descriptor,
                buffer.baseAddress!.advanced(by: offset),
                count,
                0
            )
        }
        if result >= 0 {
            return .bytes(result)
        }
        if errno == EINTR {
            return .interrupted
        }
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return .wouldBlock
        }
        return .failed(errno)
    }

    private func writeResponse(
        _ response: NotificationProtocol.Response,
        timeoutNanoseconds: UInt64
    ) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        let payload = try NotificationProtocol.encodeResponse(response)
        let frame = try NotificationProtocol.encodeFrame(payload)
        var offset = 0
        try frame.withUnsafeBytes { bytes in
            while offset < bytes.count {
                try ensureBeforeDeadline(deadline)
                let result = Darwin.send(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result == 0 {
                    throw LocalSocketServerError.incompleteRequest
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try waitUntilReady(events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                throw LocalSocketServerError.socketOperation(errno)
            }
        }
        try ensureBeforeDeadline(deadline)
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else {
            throw LocalSocketServerError.socketOperation(errno)
        }
    }

    private func waitUntilReady(events: Int16, deadline: UInt64) throws {
        switch LocalSocketOperations.waitFor(descriptor, events: events, deadline: deadline) {
        case .ready:
            return
        case .timedOut:
            throw LocalSocketServerError.timedOut
        case .failed(let error):
            throw LocalSocketServerError.socketOperation(error)
        }
    }

    private func ensureBeforeDeadline(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            throw LocalSocketServerError.timedOut
        }
    }
}

/// Shares the main-actor response with its waiting worker under a lock.
///
/// `@unchecked Sendable` makes this lock discipline the type's responsibility.
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NotificationProtocol.Response?

    func store(_ response: NotificationProtocol.Response) {
        lock.lock()
        stored = response
        lock.unlock()
    }

    func load() -> NotificationProtocol.Response? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
