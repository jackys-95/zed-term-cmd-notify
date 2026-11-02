import CoreFoundation
import Darwin
import Foundation

/// Supplies an object whose identity can be checked across binding and delivery.
///
/// Each server run captures this same object. Delivery uses `===`, Swift's
/// reference-identity comparison, to check that the binding retained it.
private final class InteropSource {}

/// Identifies a socket filesystem entry by its device and inode.
///
/// Comparing these values detects replacement of the endpoint during the
/// competing-helper check.
private struct InteropFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

/// Runs a Swift socket server with fake capture and delivery for the Rust example.
///
/// `make socket-interop` supplies an isolated absolute socket path in a private
/// directory and coordinates these command modes:
/// - `interop` checks source identity, 31,000 elapsed milliseconds, and exit code 7.
/// - `disconnect-interop` also delays the first capture to force a Rust timeout.
/// - `expect-live-lock` checks that a competing helper preserves a live endpoint.
/// - `leave-stale` exits with a socket entry left behind.
/// - `recover-stale` starts a later server at that entry and shuts it down.
///
/// Both exchange modes use the server's default four workers. Handlers run on the
/// main actor, which serializes access to the fake capture and delivery state.
/// Socket I/O runs on worker threads. The Makefile removes the temporary directory;
/// normal server shutdown removes its owned socket and retains the lock file.
///
/// These checks run without Zed, Accessibility permission, or native notifications.
/// See `docs/local-socket-transport.md` for the repository's transport contract.
@main
struct SocketInteropServer {
    /// Runs the selected command with its socket path and propagates check failures.
    ///
    /// Requires exactly a command mode and a socket path. Startup and validation
    /// failures escape this entry point so the process exits unsuccessfully.
    @MainActor
    static func main() throws {
        var arguments = CommandLine.arguments.dropFirst()
        guard let command = arguments.first else {
            throw SocketInteropError.usage
        }
        arguments = arguments.dropFirst()
        guard let socketPath = arguments.first else {
            throw SocketInteropError.usage
        }
        arguments = arguments.dropFirst()

        switch command {
        case "interop":
            guard arguments.isEmpty else {
                throw SocketInteropError.usage
            }
            try runInteropServer(socketPath: socketPath, delayFirstCapture: false)
        case "disconnect-interop":
            guard arguments.isEmpty else {
                throw SocketInteropError.usage
            }
            try runInteropServer(socketPath: socketPath, delayFirstCapture: true)
        case "expect-live-lock":
            guard arguments.isEmpty else {
                throw SocketInteropError.usage
            }
            try verifyLiveEndpointIsPreserved(socketPath: socketPath)
        case "leave-stale":
            guard arguments.isEmpty else {
                throw SocketInteropError.usage
            }
            try leaveStaleEndpoint(socketPath: socketPath)
        case "recover-stale":
            guard arguments.isEmpty else {
                throw SocketInteropError.usage
            }
            try recoverStaleEndpoint(socketPath: socketPath)
        default:
            throw SocketInteropError.usage
        }
    }

    /// Checks fake delivery and waits for server shutdown before reporting success.
    ///
    /// The main run loop lets main-actor request tasks and the shutdown callback
    /// execute while this synchronous driver waits. Delivery and shutdown waits
    /// each use an eight-second cutoff. Shutdown waits for active exchanges,
    /// including any response attempt to the timed-out Rust connection.
    ///
    /// - Parameters:
    ///   - socketPath: An isolated absolute endpoint path accepted by the server.
    ///   - delayFirstCapture: Whether to block the first capture for 2.3 seconds,
    ///     beyond Rust's two-second deadline. This simulates slow synchronous
    ///     capture; later captures have no injected delay.
    /// - Throws: Endpoint or startup errors, a shutdown timeout, or missing or
    ///   mismatched delivery.
    @MainActor
    private static func runInteropServer(
        socketPath: String,
        delayFirstCapture: Bool
    ) throws {
        let source = InteropSource()
        var deliveryPassed = false
        var deliveryFinished = false
        var captureCalls = 0
        let handler = NotificationRequestHandler<InteropSource>(
            captureSource: {
                captureCalls += 1
                if delayFirstCapture && captureCalls == 1 {
                    Thread.sleep(forTimeInterval: 2.3)
                }
                return source
            },
            deliverCompletion: { deliveredSource, elapsedMS, exitCode in
                deliveryPassed = deliveredSource === source
                    && elapsedMS == 31_000
                    && exitCode == 7
                deliveryFinished = true
            }
        )
        let server = try LocalSocketServer(endpointPath: socketPath) { request in
            handler.handle(request)
        }
        try server.start()
        print("READY")
        fflush(stdout)

        let requestDeadline = Date(timeIntervalSinceNow: 8)
        while !deliveryFinished && Date() < requestDeadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        var serverStopped = false
        server.stop {
            serverStopped = true
        }
        let shutdownDeadline = Date(timeIntervalSinceNow: 8)
        while !serverStopped && Date() < shutdownDeadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        guard serverStopped else {
            throw SocketInteropError.shutdownTimedOut
        }
        guard deliveryFinished && deliveryPassed else {
            throw SocketInteropError.deliveryMismatch
        }
        print("PASS: Swift delivered to the identical captured object with the expected completion values.")
    }

    /// Checks that a second helper fails to acquire the lock and preserves the socket.
    ///
    /// The caller must keep the original server running. The Makefile follows
    /// this check with a Rust exchange to verify that server remains usable.
    ///
    /// - Throws: An endpoint-inspection error, unexpected startup result, or
    ///   changed device and inode identity.
    private static func verifyLiveEndpointIsPreserved(socketPath: String) throws {
        let before = try fileIdentity(at: socketPath)
        let secondServer = try LocalSocketServer(endpointPath: socketPath) { _ in
            .error(.invalidRequest)
        }
        do {
            try secondServer.start()
            throw SocketInteropError.secondServerStarted
        } catch LocalSocketServerError.lockHeld {
            let after = try fileIdentity(at: socketPath)
            guard before == after else {
                throw SocketInteropError.endpointChanged
            }
            print("PASS: a competing helper preserved the live endpoint.")
        }
    }

    /// Starts a server and returns so process exit leaves a stale socket entry.
    ///
    /// This command deliberately omits `stop()`. Process exit closes descriptors
    /// and releases the lock, while the socket pathname remains for the next
    /// command to recover. The Makefile checks that entry and owns final cleanup.
    ///
    /// - Throws: Endpoint validation or server startup errors.
    private static func leaveStaleEndpoint(socketPath: String) throws {
        let server = try LocalSocketServer(endpointPath: socketPath) { _ in
            .error(.invalidRequest)
        }
        try server.start()
        print("READY")
        fflush(stdout)
        // Process exit releases the lifetime lock and leaves the socket node.
        withExtendedLifetime(server) {}
    }

    /// Recovers the stale socket entry and waits for orderly server shutdown.
    ///
    /// The caller must first run `leave-stale` at this endpoint. Server startup
    /// applies the normal ownership and stale-entry checks. The Makefile verifies
    /// socket removal after this command succeeds.
    ///
    /// - Throws: Endpoint or startup errors, or a shutdown timeout.
    @MainActor
    private static func recoverStaleEndpoint(socketPath: String) throws {
        let server = try LocalSocketServer(endpointPath: socketPath) { _ in
            .error(.invalidRequest)
        }
        try server.start()
        var serverStopped = false
        server.stop {
            serverStopped = true
        }
        let shutdownDeadline = Date(timeIntervalSinceNow: 8)
        while !serverStopped && Date() < shutdownDeadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        guard serverStopped else {
            throw SocketInteropError.shutdownTimedOut
        }
        print("PASS: a later helper removed the stale endpoint and shut down cleanly.")
    }

    /// Returns the device and inode of the entry at the supplied endpoint path.
    ///
    /// `lstat` inspects the entry itself and leaves any symbolic link unresolved.
    /// Server startup is responsible for validating the endpoint's type and owner.
    ///
    /// - Throws: `endpointMissing` if filesystem inspection fails.
    private static func fileIdentity(at path: String) throws -> InteropFileIdentity {
        var status = stat()
        guard path.withCString({ lstat($0, &status) }) == 0 else {
            throw SocketInteropError.endpointMissing
        }
        return InteropFileIdentity(device: status.st_dev, inode: status.st_ino)
    }
}

/// Reports command, endpoint-preservation, shutdown, and fake-delivery check failures.
private enum SocketInteropError: Error {
    case usage
    case secondServerStarted
    case endpointChanged
    case endpointMissing
    case shutdownTimedOut
    case deliveryMismatch
}
