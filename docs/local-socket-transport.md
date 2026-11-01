# Local Unix Socket Transport v1

**Status:** Approved design; Rust client reviewed and committed. Swift server split into focused components; behavior review and verification after the refactor remain pending. Socket interoperability remains deferred.

## Purpose and scope

This transport connects the Rust local client to the Swift macOS helper over a local Unix-domain stream socket. It uses the existing [v1 JSON messages and framing](../protocol/README.md) without changing the payload schema. This document defines the local transport beneath the [initial design](initial-design.md); the [implementation plan](implementation-plan.md) tracks progress.

V1 provides one stable per-user endpoint for one helper associated with one Zed app instance. A second helper must fail startup without disturbing the active helper. Support for multiple simultaneous Zed app instances is deferred.

This slice covers endpoint ownership and cleanup, socket client and server behavior, bounded I/O and connection capacity, and cross-language tests with fake capture and delivery. Helper auto-start, live Accessibility capture, notifications, shell hooks, tmux, and SSH remain separate work.

## Endpoint ownership and cleanup

Use these paths under the current user's Application Support directory:

```text
~/Library/Application Support/zed-term-cmd-notify/helper.sock
~/Library/Application Support/zed-term-cmd-notify/helper.lock
```

The product directory must be owned by the current user with mode `0700`. The lock and socket must be owned by that user with mode `0600`. Reject unexpected file types, symlinks, owners, or permissions without changing them.

Before any filesystem operation, Rust and Swift validate that the resolved socket pathname fits the conventional `sockaddr_un.sun_path` representation. Count encoded pathname bytes and the terminating NUL. The conventional field is 104 bytes, allowing a null-terminated pathname of at most 103 bytes. Do not truncate the path or use extended pathname encoding. An overlength path returns a clear endpoint-too-long error before directory creation, lock-file access, or socket inspection and cleanup. See [Apple DTS's Unix socket pathname guidance](https://developer.apple.com/forums/thread/817602).

Startup follows this sequence:

1. Create the private product directory if absent, or validate the existing directory.
2. Open the lock file without following symlinks and validate its type, owner, and permissions.
3. Acquire a nonblocking exclusive `flock`. If another helper holds the lock, fail without inspecting or changing the socket.
4. With the lock held, bind if the socket path is absent. If a socket exists, validate its type, owner, and permissions, then probe it. Preserve the endpoint and fail startup if a connection succeeds. A refused connection permits stale cleanup; any ambiguous result means fail without cleanup.
5. Hold the lock throughout the helper's lifetime and shutdown cleanup.

Every helper startup path must follow this sequence because [`flock` is advisory](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html). Keep the lock file after shutdown.

At shutdown, close the listener and unlink the socket only if it is still the same socket inode created by that helper. Release the lock afterward. A crash releases the lock but may leave the socket node, which the next startup can inspect. The application that binds a Unix-domain socket is responsible for [removing its filesystem entry](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/bind.2.html).

## Request and response contract

Use one connection per request:

| Rust request | Swift handler operation | Response |
| --- | --- | --- |
| `bind` | Capture the source | `bound` with a binding ID |
| `complete` with that ID | Deliver the retained source, duration, and exit status | `accepted` |

A frame contains a four-byte big-endian payload length followed by UTF-8 JSON. The payload must contain **1–4,096 bytes**, making the maximum complete frame **4,100 bytes**. Validate the length before allocating the payload.

Rust writes one complete request frame, then shuts down its write side. Swift reads the header and declared payload, followed by a one-byte EOF check:

- EOF confirms one complete request.
- An extra byte is trailing data; reject it before invoking the handler.
- No EOF by the request deadline means the peer stalled; close the connection.

Swift dispatches the validated request to the existing main-actor handler, writes one framed response, shuts down its write side, and closes. Rust reads the response and performs the same EOF check. It returns the response only after seeing EOF; extra bytes are a protocol error.

Both sides loop over [partial reads](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/recv.2.html) and writes. [`shutdown(SHUT_WR)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/shutdown.2.html) ends the sending direction while leaving the receiving direction available.

Malformed framed requests receive `invalid_request` or `unsupported_version` when possible. An oversized length receives `request_too_large` without reading or allocating the payload. Incomplete frames and trailing data are rejected. If the server cannot safely send an error response, it closes the connection.

Unavailable helpers, timeouts, connection closure, and capacity rejection remain client-side transport errors and introduce no wire error codes. `accepted` acknowledges protocol processing; it does not guarantee a visible notification.

## Deadlines and nonblocking I/O

The initial deadlines are provisional:

| Operation | Budget | Starts | Covers |
| --- | --- | --- | --- |
| Rust exchange | 2 seconds | Connection attempt begins | Connect, request write, response read, and response EOF |
| Swift request | 2 seconds | Connection is accepted | Queue wait, header, payload, and request EOF |
| Swift response | 2 seconds | Response is ready | Complete response write |

Use monotonic deadlines and nonblocking socket I/O with readiness waits, such as `poll`. Recompute the remaining time after each wait. Retry interrupted or would-block operations only while time remains. Receiving or sending more bytes does not reset a deadline.

Ordinary [`SO_RCVTIMEO` and `SO_SNDTIMEO` settings](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setsockopt.2.html) are insufficient for these absolute budgets because their timeout behavior can reset as data moves.

The client deadline is a responsiveness budget. The current capture code performs two focused-window queries plus Accessibility process-owner and role checks, using a provisional 0.75-second Accessibility timeout. A successful capture may outlast the caller's two seconds.

Socket I/O stays off the main actor. Only fully validated requests reach the main-actor handler. Handling already underway may finish after Rust times out, leaving the client uncertain whether the request took effect. The client therefore does not automatically retry. A timed-out completion is not resent; a timed-out bind leaves no cached token and may be attempted again at a later eligible launch. A transport timeout alone does not invalidate an existing binding.

## Connection capacity and peer disconnects

Use these initial capacity settings:

| Resource | Limit |
| --- | --- |
| Listen backlog | 8 pending connections |
| I/O workers | 4 |
| Accepted-connection queue | 4 |
| Total accepted-connection slots | 8 |

Hold each accepted slot through request handling, the response attempt, and connection cleanup. Queued connections retain their original accept-time deadlines. If a deadline has expired when a worker takes the connection, close it without invoking the handler.

When capacity is full, close newly accepted connections without a protocol response. Do not create additional workers or an unbounded queue.

Set `SO_NOSIGPIPE` on every Rust client socket and accepted Swift socket before writing. If setting the option fails, close that socket before writing. Treat `EPIPE` as a connection failure and keep the helper running. Leave the process-wide SIGPIPE setting unchanged. See [Apple's broken-pipe guidance](https://developer.apple.com/forums/thread/773307) and [socket option documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setsockopt.2.html).

## Validation

The integration test connects the real Rust client to the Swift server over a Unix socket. Fake capture returns a source object; Rust receives its binding ID and sends a completion using it. Fake delivery must receive that same object with the expected duration and exit status, and Rust must receive `accepted`. This exercises both codecs and the transport without requiring Zed, Accessibility permission, or native notifications. These checks remain required evidence for the deferred interoperability slice.

The current Rust change provides endpoint selection, `bind`, and `complete`, with ownership and permission checks, bounded framing, nonblocking I/O, one monotonic exchange deadline, and macOS `SO_NOSIGPIPE`. Its unit tests cover pathname boundaries, a regular file at the socket path, an unavailable helper, fragmented responses, malformed and incomplete responses, oversized lengths, trailing data, a withheld response, a complete response with withheld EOF, and slow fragments that exceed the original exchange deadline.

User-provided results confirm that `cargo build --workspace --locked`, `cargo test --workspace --locked`, and `cargo fmt --all -- --check` passed for the isolated Rust slice after the style and deadline-test updates. All 16 unit tests passed: eight protocol tests and eight transport tests. The usage example also passed its compile-only documentation check; it was not executed against a helper. Real Rust-to-Swift socket integration remains pending separate review.

The Swift transport separates server coordination, endpoint ownership, connection exchanges, and shared Darwin operations as described in the [code layout](code-layout.md). The helper app starts the server when launched and stops it during termination. Bind requests call the existing retained-window capture code. Completion requests look up the retained source and call the app's delivery callback, whose body is currently empty.

User-provided results confirm `xcodebuild test` succeeded after restoration and before the file split: all 26 Swift tests passed, comprising 18 existing helper tests and eight [socket-server tests](../macos/NotificationHelperTests/LocalSocketServerTests.swift). The Xcode test scheme disables startup at the default endpoint so tests can use isolated endpoints. The eight socket-server tests are unchanged by the refactor. Swift behavior review, Xcode verification after the refactor, and real Rust-to-Swift socket integration remain pending.

| Area | Cases | Required result |
| --- | --- | --- |
| Framing | Fragmented reads and writes, premature EOF, malformed JSON, unsupported versions, oversized lengths, and trailing bytes in both directions | Valid exchanges complete; invalid messages fail. Rejected requests never invoke capture or delivery. |
| Deadlines | Unavailable helper, withheld response, stalled header or payload, and missing request half-close | Each operation returns within its configured deadline. |
| Disconnects | Rust times out and closes before Swift replies | Swift handles the failed write and serves a subsequent request. |
| Capacity | Stalled connections fill workers and queue; excess connections arrive; queued requests expire | Excess connections close promptly. Expired queued requests never reach the handler. Released slots allow service to resume. |
| Endpoint lifecycle | Concurrent startup, an existing live endpoint, crash recovery, shutdown, and unexpected filesystem entries | The active helper remains usable. Cleanup removes only the appropriate socket; unexpected entries remain untouched. |
| Path limits | Accepted and rejected encoded-byte boundaries in both implementations | Overlength paths fail clearly before any filesystem changes. |
