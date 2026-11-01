# Code Layout

**Status:** Evolving. This note describes the current source and build organization and is expected to evolve as implementation exposes new constraints.

The layout follows the component boundaries in the [initial design](initial-design.md). Rust and Swift retain their own build definitions; a small root-level Makefile provides convenient commands that run both.

## Proposed layout

| Path | Purpose |
| --- | --- |
| `Cargo.toml` | Root Rust workspace manifest for workspace membership and shared settings. |
| `crates/local-client/` | Rust workspace package. Its request/response codec and tests are implemented; the command-line IPC client will be added with the local client slice. Add the SSH launcher and remote sender as separate Rust packages when their implementation slices begin. |
| `macos/NotificationHelper.xcodeproj` and `macos/NotificationHelper/` | Swift helper app target and source. `App/` owns startup and helper lifetime; `IPC/` receives and validates client requests; `Bindings/` manages opaque tokens and retained window associations; `Notifications/` handles delivery and suppression; `WindowAccess/` wraps window inspection and focus actions. |
| `macos/NotificationHelperTests/` | Swift helper tests using fake window and notification operations. |
| `protocol/` | Version 1 request/response contract and synthetic fixtures shared by Rust and Swift tests. The current codec uses length-prefixed JSON with a bounded payload and explicit versioning. |
| `zsh/` | Interactive hooks and tmux entry integration, added with their implementation slice. Zsh owns eligibility, exclusions, command timing, and exit-status capture. |
| `Makefile` | Root-level build and test targets that delegate to Cargo and Xcode. Component-specific build settings remain in the Cargo workspace and Xcode project. |

## Build and test entry points

Cargo builds and tests Rust workspace packages. Xcode builds and tests the Swift helper app. The root Makefile coordinates these commands; it does not replace either build system. `make test` runs both unit suites and a Rust-to-Swift-to-Rust exchange for bind, complete, bound, and accepted messages. Component targets include `make rust-test`, `make macos-test`, and `make protocol-interop`.

The Rust and Swift protocol tests run on macOS without a live Zed window or AL2023 host, using shared synthetic fixtures. Window and notification policy tests will use fake operations as that logic is implemented. Real window control, notification authorization, SSH forwarding, and remote Linux behavior remain integration checks on their respective systems.
