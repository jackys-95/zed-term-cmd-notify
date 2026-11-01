import Darwin
import Foundation

/// Reports endpoint startup failures and socket exchange failures.
enum LocalSocketServerError: Error, CustomStringConvertible {
    case endpointTooLong
    case invalidEndpoint
    case lockHeld
    case timedOut
    case incompleteRequest
    case socketOperation(Int32)

    var description: String {
        switch self {
        case .endpointTooLong:
            "endpoint path is too long"
        case .invalidEndpoint:
            "endpoint is unsafe"
        case .lockHeld:
            "another helper owns the endpoint"
        case .timedOut:
            "socket operation timed out"
        case .incompleteRequest:
            "request ended before its frame completed"
        case .socketOperation(let code):
            "socket operation failed with errno \(code)"
        }
    }
}

/// Limits listener capacity, worker capacity, and socket waiting time.
///
/// The request budget starts when a connection is accepted and includes queue
/// time. The response budget starts when a response is ready to encode and send.
struct LocalSocketServerConfiguration {
    var backlog = 8
    var workerCount = 4
    var queuedConnectionLimit = 4
    var requestTimeoutNanoseconds: UInt64 = 2_000_000_000
    var responseTimeoutNanoseconds: UInt64 = 2_000_000_000
}

/// Coordinates the helper's listening endpoint and bounded connection workers.
///
/// The app starts one server and requests asynchronous shutdown during
/// termination. Each worker delegates its exchange to `LocalSocketConnection`.
/// Request handlers run on the main actor; socket waits run on worker threads.
///
/// The app controls startup and shutdown. This type uses `@unchecked Sendable`
/// to permit its background closures to capture the server.
/// The condition lock protects queue and stopping state. Startup establishes
/// the endpoint and wake pipe before workers launch; shutdown closes them after
/// the accept loop and workers exit.
final class LocalSocketServer: @unchecked Sendable {
    typealias RequestHandler =
        @MainActor @Sendable (NotificationProtocol.Request) -> NotificationProtocol.Response

    private let endpoint: LocalSocketEndpoint
    private let configuration: LocalSocketServerConfiguration
    private let requestHandler: RequestHandler
    private let condition = NSCondition()
    private let acceptGroup = DispatchGroup()
    private let workerGroup = DispatchGroup()
    private var readyConnections: [LocalSocketConnection] = []
    private var waitingConnections: [LocalSocketConnection] = []
    private var occupiedWorkerSlots = 0
    private var stopping = false
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var started = false

    init(
        endpointPath: String,
        configuration: LocalSocketServerConfiguration = .init(),
        handler: @escaping RequestHandler
    ) throws {
        endpoint = try LocalSocketEndpoint(path: endpointPath)
        self.configuration = configuration
        requestHandler = handler
    }

    static func defaultEndpointPath() throws -> String {
        try LocalSocketEndpoint.defaultPath()
    }

    static func validateEndpointPath(_ path: String) throws {
        try LocalSocketOperations.validatePath(path)
    }

    /// Opens the endpoint and launches the accept loop and workers.
    ///
    /// Repeated calls while started return without launching additional workers.
    /// Startup errors close acquired resources and propagate to the app.
    func start() throws {
        condition.lock()
        guard !started else {
            condition.unlock()
            return
        }
        started = true
        condition.unlock()

        do {
            guard configuration.workerCount > 0,
                  configuration.queuedConnectionLimit > 0,
                  configuration.backlog > 0
            else {
                throw LocalSocketServerError.invalidEndpoint
            }
            try endpoint.openListener(backlog: Int32(configuration.backlog))
            try createWakePipe()
            for _ in 0..<configuration.workerCount {
                workerGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { workerGroup.leave() }
                    workerLoop()
                }
            }
            acceptGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { acceptGroup.leave() }
                acceptLoop()
            }
        } catch {
            endpoint.closeAndCleanup()
            closeWakePipe()
            condition.lock()
            started = false
            condition.unlock()
            throw error
        }
    }

    /// Stops admission, closes queued connections, and waits for active workers.
    ///
    /// The first call schedules cleanup and invokes completion on the main actor
    /// afterward. Calls before startup or during shutdown schedule their own
    /// completion immediately. Create a new server for a later listening session.
    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        condition.lock()
        guard started, !stopping else {
            condition.unlock()
            Task { @MainActor in completion() }
            return
        }
        stopping = true
        let queuedConnections = readyConnections + waitingConnections
        readyConnections.removeAll()
        waitingConnections.removeAll()
        condition.broadcast()
        condition.unlock()

        queuedConnections.forEach { _ = Darwin.close($0.descriptor) }
        if wakeWrite >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            acceptGroup.wait()
            workerGroup.wait()
            endpoint.closeAndCleanup()
            closeWakePipe()
            Task { @MainActor in completion() }
        }
    }

    private func createWakePipe() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw LocalSocketServerError.socketOperation(errno)
        }
        wakeRead = descriptors[0]
        wakeWrite = descriptors[1]
        for descriptor in descriptors {
            guard LocalSocketOperations.setNonblocking(descriptor),
                  LocalSocketOperations.setCloseOnExec(descriptor)
            else {
                let error = errno
                closeWakePipe()
                throw LocalSocketServerError.socketOperation(error)
            }
        }
    }

    private func closeWakePipe() {
        if wakeRead >= 0 {
            _ = Darwin.close(wakeRead)
            wakeRead = -1
        }
        if wakeWrite >= 0 {
            _ = Darwin.close(wakeWrite)
            wakeWrite = -1
        }
    }

    private func acceptLoop() {
        while !isStopping {
            switch waitForListener() {
            case .ready:
                acceptAvailableConnections()
            case .timedOut:
                continue
            case .failed:
                return
            case .wake:
                return
            }
        }
    }

    private enum ListenerWaitResult {
        case ready
        case timedOut
        case wake
        case failed(Int32)
    }

    private func waitForListener() -> ListenerWaitResult {
        var descriptors = [
            pollfd(fd: endpoint.listener, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            let result = descriptors.withUnsafeMutableBufferPointer {
                Darwin.poll($0.baseAddress, nfds_t($0.count), -1)
            }
            if result > 0 {
                if descriptors[1].revents != 0 {
                    return .wake
                }
                if descriptors[0].revents & Int16(POLLNVAL) != 0 {
                    return .failed(EBADF)
                }
                if descriptors[0].revents != 0 {
                    return .ready
                }
            } else if result == 0 {
                return .timedOut
            } else if errno != EINTR {
                return .failed(errno)
            }
        }
    }

    private var isStopping: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopping
    }

    private func acceptAvailableConnections() {
        while !isStopping {
            let descriptor = Darwin.accept(endpoint.listener, nil, nil)
            if descriptor < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }

            guard LocalSocketOperations.setNonblocking(descriptor),
                  LocalSocketOperations.setCloseOnExec(descriptor),
                  LocalSocketOperations.setNoSigPipe(descriptor)
            else {
                _ = Darwin.close(descriptor)
                continue
            }

            let connection = LocalSocketConnection(
                descriptor: descriptor,
                acceptedAt: DispatchTime.now().uptimeNanoseconds
            )
            condition.lock()
            let atSlotLimit = occupiedWorkerSlots + waitingConnections.count
                >= configuration.workerCount + configuration.queuedConnectionLimit
            if stopping || atSlotLimit {
                condition.unlock()
                _ = Darwin.close(descriptor)
            } else if occupiedWorkerSlots < configuration.workerCount {
                occupiedWorkerSlots += 1
                readyConnections.append(connection)
                condition.signal()
                condition.unlock()
            } else if waitingConnections.count < configuration.queuedConnectionLimit {
                waitingConnections.append(connection)
                condition.unlock()
            } else {
                condition.unlock()
                _ = Darwin.close(descriptor)
            }
        }
    }

    private func workerLoop() {
        while let connection = nextConnection() {
            defer {
                condition.lock()
                // With one worker and one waiting connection, finishing the
                // current exchange promotes the waiting entry into the same
                // occupied slot. The slot count falls only when no entry follows.
                if !stopping, !waitingConnections.isEmpty {
                    readyConnections.append(waitingConnections.removeFirst())
                    condition.signal()
                } else {
                    occupiedWorkerSlots -= 1
                }
                condition.broadcast()
                condition.unlock()
            }
            connection.serve(configuration: configuration, handler: requestHandler)
        }
    }

    private func nextConnection() -> LocalSocketConnection? {
        condition.lock()
        defer { condition.unlock() }
        while readyConnections.isEmpty && !stopping {
            condition.wait()
        }
        guard !stopping, !readyConnections.isEmpty else {
            return nil
        }
        return readyConnections.removeFirst()
    }
}
