# Code Layout

**Status:** Evolving. This note describes the current source and build organization and is expected to evolve as implementation exposes new constraints.

The layout follows the component boundaries in the [initial design](initial-design.md). Rust and Swift retain their own build definitions; a small root-level Makefile provides convenient commands that run both.

## Proposed layout

| Path | Purpose |
| --- | --- |
| `Cargo.toml` | Root Rust workspace manifest for workspace membership and shared settings. |
| `crates/local-client/` | Rust workspace package with the protocol codec and socket client library for bind and completion. The command-line entry point remains a placeholder. Add the SSH launcher and remote sender as separate Rust packages when their implementation slices begin. |
| `macos/NotificationHelper.xcodeproj` and `macos/NotificationHelper/` | Swift helper app target and source. `App/` owns startup and helper lifetime; `IPC/` receives and validates client requests; `Bindings/` manages opaque tokens and retained window associations; `Notifications/` handles delivery and suppression; `WindowAccess/` wraps window inspection and focus actions. |
| `macos/NotificationHelperTests/` | Swift helper tests using fake window and notification operations. |
| `protocol/` | Version 1 request/response contract and synthetic fixtures shared by Rust and Swift tests. The current codec uses length-prefixed JSON with a bounded payload and explicit versioning. |
| `zsh/` | Interactive hooks and tmux entry integration, added with their implementation slice. Zsh owns eligibility, exclusions, command timing, and exit-status capture. |
| `Makefile` | Root-level build and test targets that delegate to Cargo and Xcode. Component-specific build settings remain in the Cargo workspace and Xcode project. |

The Swift socket transport has four files under `IPC/`.
[`LocalSocketServer.swift`](../macos/NotificationHelper/IPC/LocalSocketServer.swift)
coordinates startup, shutdown, admission, and workers.
[`LocalSocketEndpoint.swift`](../macos/NotificationHelper/IPC/LocalSocketEndpoint.swift)
owns the listener, lock, and socket cleanup.
[`LocalSocketConnection.swift`](../macos/NotificationHelper/IPC/LocalSocketConnection.swift)
serves one request and response, including the main-actor handler call.
[`LocalSocketOperations.swift`](../macos/NotificationHelper/IPC/LocalSocketOperations.swift)
contains shared Darwin socket operations.
`NotificationProtocol.swift` owns the wire format, and
`NotificationRequestHandler.swift` owns binding and completion behavior. The
AppKit app delegate connects these components to launch and termination.

The server owns queued connection descriptors. A worker takes a connection and
serves it once; that operation closes the descriptor on return. The connection
retains its acceptance time, so time spent in the queue counts toward its request
deadline. Shutdown closes queued connections and waits for active workers before
the endpoint removes its socket and releases the lock.

## Build and test entry points

Cargo builds and tests Rust workspace packages. Xcode builds and tests the Swift helper app. The root Makefile coordinates these commands; it does not replace either build system. `make test` runs both unit suites and a file-based Rust-to-Swift-to-Rust codec exchange for bind, complete, bound, and accepted messages. Component targets include `make rust-test`, `make macos-test`, and `make protocol-interop`. Real-socket interoperability drivers and Makefile integration remain deferred.

The Rust and Swift protocol tests run on macOS without a live Zed window or AL2023 host, using shared synthetic fixtures. Window and notification policy tests will use fake operations as that logic is implemented. Real window control, notification authorization, SSH forwarding, and remote Linux behavior remain integration checks on their respective systems.
