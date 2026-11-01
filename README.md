# Zed Terminal Command Notifications

A small, version-controlled project for silent macOS notifications when long-running foreground commands finish in local or remote interactive Zsh sessions used through Zed's regular integrated terminal.

## Primary workflow

Local Zsh hooks report directly to a Swift Mac helper. Remote Zsh hooks invoke a small prebuilt Rust sender to report through a reverse forward in the same interactive SSH connection, including commands in hidden remote tmux panes while their notification connection is active. The sender exits after each event; AL2023 needs no Rust toolchain or sender daemon. A Rust launcher manages the remote connection using existing SSH configuration.

Local shells capture their source Zed window lazily, on the first eligible interactive command, then cache the association for the shell's lifetime. Terminals stay in their original Zed window. Remote commands use the window captured when the SSH launcher starts. Notifications use a 30-second duration threshold, have no sound, and should focus the exact source window on click. Another Zed window being foreground is not sufficient to suppress a notification.

Manual rebinding is approved for an association that points to the wrong window. The proposed `zed-notify rebind` command captures again while the intended window is foreground, updating the local shell's cache or the remote connection's association. Issued notifications retain their original associations. This recovery command has not been implemented.

The user attaches to persistent remote tmux sessions manually, using `tmux a` or `tmux a -t session-name`, and creates new attached sessions. Entry integration must register the session actually attached or created by tmux. Direct SSH entry into the same tmux integration is a proposed convenience path; detached creation is not required for the first version. A qualifying command completion uses that session's current notification connection, so a command spanning a disconnect can notify after reconnection and reattachment. Completion while no notification connection is available is dropped, without queueing or replay. Each issued notification keeps its window association fixed.

The launcher cleans up local mouse reporting and any terminal settings it changed when SSH exits, including after connection loss or laptop sleep. Cleanup preserves terminal contents and the SSH result; reconnect remains manual. A still-running SSH process after wake defers cleanup until it exits. The cleanup sequence has not yet been validated in Zed.

## Current findings

- Local hooks can detect local command completion; remote per-command completion requires hooks in each remote interactive Zsh shell.
- The approved window baseline retains public Accessibility objects for source identity, foreground checks, and click focus. Object-only probes succeeded across Spaces, restored a minimized source window, and rejected a closed source without activating Zed.
- A small private window-ID conversion also worked experimentally; it is not part of the approved baseline. Numeric IDs, geometry matching, and stacking-order matching are unnecessary for this approach.
- These probes do not establish end-to-end local or remote notification delivery.

## Initial scope

Track local and remote Zsh hooks, the Rust SSH launcher, Swift notification helper, source-window association, and validation across local Zed terminals, plain SSH shells, and remote tmux panes. Use manual reconnect; background jobs, disconnected replay, an always-running daemon, exact pane navigation, and other terminal applications are outside the first version.

Mac-side notification eligibility requires `ZED_TERM=true` and no `ZED_NOTIFY_DISABLED=1` opt-out. Local command hooks and the SSH launcher check this before helper startup, source capture, or bridge setup. Ordinary iTerm2, cmux, and macOS Terminal sessions are excluded by the missing Zed marker.

Terminal Threads are excluded for now; they are generally used for agent harness sessions. The approved configuration exports `ZED_NOTIFY_DISABLED=1` through `agent.terminal_init_command`. The combined gate distinguishes the configured terminal surfaces even though both set `ZED_TERM=true`. A separate bounded denylist excludes Codex, Claude, and Pi invocations, expanded aliases, and explicitly configured wrappers in regular terminals.

Native OSC 9 is a conditional future design note with no implementation work in the current scope. No Zed fork is required. Do not store credentials, SSH private configuration, or generated build artifacts in this repository.

## Design and status

The authoritative scope and initial architecture are recorded in [docs/initial-design.md](docs/initial-design.md). Production implementation has not started; the Mac helper, public window-object baseline, and lazy shell binding are the selected direction. The helper starts on demand and remains alive until the associated Zed app exits, including while individual project windows close. The race before the first focus query is accepted for now and will be revisited if observed in practical use. Detected capture changes or timeouts leave the cache empty and allow the command to proceed; local-hook integration remains to be implemented.

The [lightweight implementation plan](docs/implementation-plan.md) proposes working slices, with unit tests alongside each component and integration evidence guiding subsequent iterations.

Probe scripts, API alternatives, and outcome summaries are preserved in [experiments/macos-window-notifications](experiments/macos-window-notifications/README.md). The archive distinguishes tested approaches from prototypes and uses configurable runtime directories.
