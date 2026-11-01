import Darwin
import Foundation

@_silgen_name("flock")
private func unixFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
    }
}

/// Owns the helper's listening socket, lifetime lock, and filesystem cleanup.
///
/// The server opens the endpoint before starting workers and closes it after
/// they exit. The lock stays held through socket cleanup. Only a socket with the
/// recorded device and inode is removed during normal shutdown.
final class LocalSocketEndpoint {
    let path: String
    private(set) var listener: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var socketIdentity: FileIdentity?

    init(path: String) throws {
        try LocalSocketOperations.validatePath(path)
        self.path = path
    }

    static func defaultPath() throws -> String {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else {
            throw LocalSocketServerError.invalidEndpoint
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("zed-term-cmd-notify", isDirectory: true)
            .appendingPathComponent("helper.sock", isDirectory: false)
            .path
    }

    /// Validates the private directory, acquires the lock, and starts listening.
    ///
    /// A refused connection permits stale-socket recovery. A live socket or an
    /// uncertain probe result prevents startup and preserves the existing entry.
    func openListener(backlog: Int32) throws {
        do {
            try createOrValidateDirectory()
            try acquireLock()
            try removeStaleSocketIfPresent()
            try bindListener(backlog: backlog)
        } catch {
            closeAndCleanup()
            throw error
        }
    }

    /// Closes the listener, removes its socket if unchanged, and releases the lock.
    ///
    /// If another entry has replaced the socket, its identity differs and it
    /// remains in place. Calling this again is safe.
    func closeAndCleanup() {
        if listener >= 0 {
            _ = Darwin.close(listener)
            listener = -1
        }

        if let socketIdentity, let current = fileIdentity(at: path), current == socketIdentity {
            _ = path.withCString { Darwin.unlink($0) }
        }
        socketIdentity = nil

        if lockDescriptor >= 0 {
            // Keep the lock file so all helper launches coordinate on one inode.
            _ = Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    private var directoryPath: String {
        (path as NSString).deletingLastPathComponent
    }

    private var lockPath: String {
        (path as NSString).deletingLastPathComponent + "/helper.lock"
    }

    private func createOrValidateDirectory() throws {
        var status = stat()
        let directoryStatus = directoryPath.withCString { Darwin.lstat($0, &status) }
        if directoryStatus != 0 {
            guard errno == ENOENT else {
                throw LocalSocketServerError.socketOperation(errno)
            }
            let createResult = directoryPath.withCString {
                Darwin.mkdir($0, mode_t(0o700))
            }
            if createResult != 0 && errno != EEXIST {
                throw LocalSocketServerError.socketOperation(errno)
            }
            guard directoryPath.withCString({ Darwin.lstat($0, &status) }) == 0 else {
                throw LocalSocketServerError.socketOperation(errno)
            }
        }
        guard
            status.st_uid == geteuid(),
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            status.st_mode & mode_t(0o7777) == mode_t(0o700)
        else {
            throw LocalSocketServerError.invalidEndpoint
        }
    }

    private func acquireLock() throws {
        var descriptor = lockPath.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        let created = descriptor >= 0
        if descriptor < 0 {
            guard errno == EEXIST else {
                throw LocalSocketServerError.socketOperation(errno)
            }
            descriptor = lockPath.withCString {
                Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            }
        }
        guard descriptor >= 0 else {
            throw LocalSocketServerError.socketOperation(errno)
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            throw LocalSocketServerError.socketOperation(error)
        }
        if created {
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                let error = errno
                _ = Darwin.close(descriptor)
                throw LocalSocketServerError.socketOperation(error)
            }
            guard Darwin.fstat(descriptor, &status) == 0 else {
                let error = errno
                _ = Darwin.close(descriptor)
                throw LocalSocketServerError.socketOperation(error)
            }
        }
        guard
            status.st_uid == geteuid(),
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            status.st_mode & mode_t(0o7777) == mode_t(0o600),
            status.st_nlink == 1
        else {
            _ = Darwin.close(descriptor)
            throw LocalSocketServerError.invalidEndpoint
        }

        guard unixFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw LocalSocketServerError.lockHeld
            }
            throw LocalSocketServerError.socketOperation(error)
        }
        lockDescriptor = descriptor
    }

    private func removeStaleSocketIfPresent() throws {
        var status = stat()
        let result = path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else {
                throw LocalSocketServerError.socketOperation(errno)
            }
            return
        }
        guard
            status.st_uid == geteuid(),
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
            status.st_mode & mode_t(0o7777) == mode_t(0o600)
        else {
            throw LocalSocketServerError.invalidEndpoint
        }

        switch try probeExistingSocket() {
        case .active:
            throw LocalSocketServerError.lockHeld
        case .stale:
            let observedIdentity = FileIdentity(status)
            guard fileIdentity(at: path) == observedIdentity else {
                throw LocalSocketServerError.invalidEndpoint
            }
            guard path.withCString({ Darwin.unlink($0) }) == 0 else {
                throw LocalSocketServerError.socketOperation(errno)
            }
        case .ambiguous(let error):
            throw LocalSocketServerError.socketOperation(error)
        }
    }

    private enum ProbeResult {
        case active
        case stale
        case ambiguous(Int32)
    }

    private func probeExistingSocket() throws -> ProbeResult {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .ambiguous(errno)
        }
        defer { _ = Darwin.close(descriptor) }
        guard LocalSocketOperations.setNonblocking(descriptor),
              LocalSocketOperations.setCloseOnExec(descriptor),
              LocalSocketOperations.setNoSigPipe(descriptor)
        else {
            return .ambiguous(errno)
        }

        var address = try LocalSocketOperations.socketAddress(for: path)
        let addressLength = LocalSocketOperations.socketAddressLength(for: path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            Darwin.connect(
                descriptor,
                UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self),
                addressLength
            )
        }
        if connectResult == 0 {
            return .active
        }
        if errno == ECONNREFUSED {
            return .stale
        }
        if errno != EINPROGRESS && errno != EALREADY && errno != EINTR && errno != EWOULDBLOCK {
            return .ambiguous(errno)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds &+ 250_000_000
        switch LocalSocketOperations.waitFor(descriptor, events: Int16(POLLOUT), deadline: deadline) {
        case .ready:
            var socketError: Int32 = 0
            var optionLength = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &optionLength
            ) == 0 else {
                return .ambiguous(errno)
            }
            return socketError == 0
                ? .active
                : (socketError == ECONNREFUSED ? .stale : .ambiguous(socketError))
        case .timedOut:
            return .ambiguous(ETIMEDOUT)
        case .failed(let error):
            return .ambiguous(error)
        }
    }

    private func bindListener(backlog: Int32) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LocalSocketServerError.socketOperation(errno)
        }
        guard LocalSocketOperations.setNonblocking(descriptor),
              LocalSocketOperations.setCloseOnExec(descriptor),
              LocalSocketOperations.setNoSigPipe(descriptor)
        else {
            let error = errno
            _ = Darwin.close(descriptor)
            throw LocalSocketServerError.socketOperation(error)
        }

        var address = try LocalSocketOperations.socketAddress(for: path)
        let length = LocalSocketOperations.socketAddressLength(for: path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            Darwin.bind(
                descriptor,
                UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr.self),
                length
            )
        }
        guard bindResult == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            throw LocalSocketServerError.socketOperation(error)
        }

        guard path.withCString({ Darwin.chmod($0, mode_t(0o600)) }) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            _ = path.withCString { Darwin.unlink($0) }
            throw LocalSocketServerError.socketOperation(error)
        }
        guard Darwin.listen(descriptor, backlog) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            _ = path.withCString { Darwin.unlink($0) }
            throw LocalSocketServerError.socketOperation(error)
        }

        var status = stat()
        guard path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
            let error = errno
            _ = Darwin.close(descriptor)
            _ = path.withCString { Darwin.unlink($0) }
            throw LocalSocketServerError.socketOperation(error)
        }
        guard
            status.st_uid == geteuid(),
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
            status.st_mode & mode_t(0o7777) == mode_t(0o600)
        else {
            _ = Darwin.close(descriptor)
            throw LocalSocketServerError.invalidEndpoint
        }

        listener = descriptor
        socketIdentity = FileIdentity(status)
    }

    private func fileIdentity(at path: String) -> FileIdentity? {
        var status = stat()
        guard path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
            return nil
        }
        return FileIdentity(status)
    }
}
