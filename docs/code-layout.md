# Code Layout

**Status:** Proposed. This note describes the current source and build organization and is expected to evolve as implementation exposes new constraints.

The layout follows the component boundaries in the [initial design](initial-design.md). Rust and Swift retain their own build definitions; a small root-level Makefile provides convenient commands that run both.

## Proposed layout

| Path | Purpose |
| --- | --- |
| `Cargo.toml` | Root Rust workspace manifest for workspace membership and shared settings. |
| `crates/local-client/` | Short-lived Rust client invoked by Zsh for binding and completion requests. It contains the command-line entry point, local IPC client, request/response handling, and Rust tests. Add the SSH launcher and remote sender as separate Rust packages when their implementation slices begin. |
| `macos/NotificationHelper.xcodeproj` and `macos/NotificationHelper/` | Swift helper app target and source. `App/` owns startup and helper lifetime; `IPC/` receives and validates client requests; `Bindings/` manages opaque tokens and retained window associations; `Notifications/` handles delivery and suppression; `WindowAccess/` wraps window inspection and focus actions. |
| `macos/NotificationHelperTests/` | Swift helper tests using fake window and notification operations. |
| `protocol/` | Proposed request/response messages and synthetic fixtures shared by Rust and Swift tests. Wire framing, payload limits, response semantics, and explicit versioning remain open. |
| `zsh/` | Interactive hooks and tmux entry integration, added with their implementation slice. Zsh owns eligibility, exclusions, command timing, and exit-status capture. |
| `Makefile` | Root-level build and test targets that delegate to Cargo and Xcode. Component-specific build settings remain in the Cargo workspace and Xcode project. |

## Build and test entry points

Cargo builds and tests Rust workspace packages. Xcode builds and tests the Swift helper app. The root Makefile coordinates these commands; it does not replace either build system. Planned targets include a combined `make build` and `make test`, with component-specific targets such as `make rust-test` and `make macos-test`.

The Rust and Swift unit tests should run on macOS without a live Zed window or AL2023 host. Swift tests use fake window and notification operations. Real window control, notification authorization, SSH forwarding, and remote Linux behavior remain integration checks on their respective systems.
