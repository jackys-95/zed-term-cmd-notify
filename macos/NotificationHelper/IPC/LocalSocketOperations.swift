import Darwin
import Foundation

/// Shared Darwin operations used by endpoint startup and connection I/O.
///
/// Callers own the descriptors passed here. Readiness waits use an absolute
/// deadline in monotonic uptime nanoseconds, so interruptions preserve the budget.
enum LocalSocketOperations {
    enum ReadinessResult {
        case ready
        case timedOut
        case failed(Int32)
    }

    /// Checks that an absolute pathname and its terminating NUL fit `sockaddr_un`.
    ///
    /// The conventional 104-byte field holds 103 pathname bytes plus the NUL.
    /// UTF-8 characters can occupy several bytes.
    static func validatePath(_ path: String) throws {
        let bytes = Array(path.utf8)
        guard path.hasPrefix("/"), !bytes.isEmpty, !bytes.contains(0) else {
            throw LocalSocketServerError.invalidEndpoint
        }
        let address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count + 1 <= capacity else {
            throw LocalSocketServerError.endpointTooLong
        }
    }

    static func waitFor(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64
    ) -> ReadinessResult {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                return .timedOut
            }
            let remaining = deadline - now
            let timeout = Int32(min((remaining + 999_999) / 1_000_000, UInt64(Int32.max)))
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, max(timeout, 1))
            if result > 0 {
                if item.revents & Int16(POLLNVAL) != 0 {
                    return .failed(EBADF)
                }
                return .ready
            }
            if result == 0 {
                return .timedOut
            }
            if errno != EINTR {
                return .failed(errno)
            }
        }
    }

    static func setNonblocking(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        return flags >= 0 && Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0
    }

    static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        return flags >= 0 && Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) >= 0
    }

    /// Makes writes to a disconnected peer return an error without raising SIGPIPE.
    static func setNoSigPipe(_ descriptor: Int32) -> Bool {
        var enabled: Int32 = 1
        return Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    }

    static func socketAddress(for path: String) throws -> sockaddr_un {
        try validatePath(path)
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        let pathOffset = MemoryLayout<sockaddr_un>.size
            - MemoryLayout.size(ofValue: address.sun_path)
        let addressLength = pathOffset + bytes.count
        address.sun_len = UInt8(addressLength)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        return address
    }

    static func socketAddressLength(for path: String) -> socklen_t {
        let address = sockaddr_un()
        let pathOffset = MemoryLayout<sockaddr_un>.size
            - MemoryLayout.size(ofValue: address.sun_path)
        return socklen_t(pathOffset + path.utf8.count + 1)
    }
}
