# Zed Terminal Command Notifications

A small, version-controlled project for silent macOS notifications when long-running foreground commands finish in local or remote interactive Zsh sessions used through Zed's regular integrated terminal.

## Supported workflows

The design covers ordinary local Zsh shells, local tmux panes, plain SSH shells, and remote tmux panes. All four report command completion to the same Swift Mac helper for silent notifications, source-window filtering, and click focus. Notifications use a 30-second duration threshold and should focus the exact source window on click. Another Zed window being foreground is not sufficient to suppress a notification.

Local Zsh hooks report through a short-lived Rust local client. Ordinary local shells outside tmux capture their source Zed window lazily, on the first eligible interactive command, then cache the association for the shell's lifetime. Those terminals stay in their original Zed window. Local tmux captures a window binding from the eligible attaching terminal; pane hooks use the session's current binding at qualifying completion, including after reattachment in another window. Local tmux uses the ordinary local delivery client and requires no SSH connection registration.

Remote Zsh hooks invoke a small prebuilt Rust sender to report through a reverse forward in the same interactive SSH connection, including commands in hidden remote tmux panes while their notification connection is active. A Rust launcher manages the remote connection using existing SSH configuration and captures its source Zed window at startup. The sender exits after each event; the initial Linux target is AL2023, which needs no Rust toolchain or sender daemon.

Manual rebinding is approved for an association that points to the wrong window. The proposed `zed-notify rebind` command captures again while the intended window is foreground, updating the ordinary local shell's cache, the local tmux session's binding, or the remote connection's association. Delivery while local tmux is detached and ownership with simultaneous clients remain open policy decisions. Issued notifications retain their original associations. This recovery command has not been implemented.

Local and remote tmux support manual `tmux a` or `tmux a -t session-name` attachment and new attached sessions. Entry integration must publish the notification context to the session actually attached or created by tmux. Direct SSH entry into the same tmux integration is a proposed convenience path; detached creation is not required for the first version. In remote tmux, a qualifying completion uses the session's current notification connection, so a command spanning a disconnect can notify after reconnection and reattachment. Remote completion while no notification connection is available is dropped, without queueing or replay. Each issued notification keeps its window association fixed.

The launcher cleans up local mouse reporting and any terminal settings it changed when SSH exits, including after connection loss or laptop sleep. Cleanup preserves terminal contents and the SSH result; reconnect remains manual. A still-running SSH process after wake defers cleanup until it exits. The cleanup sequence has not yet been validated in Zed.

## Current findings

- Local hooks can detect local command completion; remote per-command completion requires hooks in each remote interactive Zsh shell.
- The approved window baseline retains public Accessibility objects for source identity, foreground checks, and click focus. Object-only probes succeeded across Spaces, restored a minimized source window, and rejected a closed source without activating Zed.
- A small private window-ID conversion also worked experimentally; it is not part of the approved baseline. Numeric IDs, geometry matching, and stacking-order matching are unnecessary for this approach.
- These probes do not establish end-to-end local or remote notification delivery.

## Initial scope

Track local and remote Zsh hooks, the Rust SSH launcher, Swift notification helper, source-window association, and validation across ordinary local Zed shells, local tmux panes, plain SSH shells, and remote tmux panes. Use manual reconnect; background jobs, disconnected replay, an always-running daemon, exact pane navigation, and other terminal applications are outside the first version.

Mac-side notification eligibility requires `ZED_TERM=true` and no `ZED_NOTIFY_DISABLED=1` opt-out. Ordinary local command hooks, local tmux entry integration, and the SSH launcher check this before helper startup, source capture, or bridge setup. Local tmux entry must check the attaching terminal rather than rely on surviving panes' inherited markers. Ordinary iTerm2, cmux, and macOS Terminal sessions are excluded by the missing Zed marker.

Terminal Threads are excluded for now; they are generally used for agent harness sessions. The approved configuration exports `ZED_NOTIFY_DISABLED=1` through `agent.terminal_init_command`. The combined gate distinguishes the configured terminal surfaces even though both set `ZED_TERM=true`. A separate bounded denylist excludes Codex, Claude, and Pi invocations, expanded aliases, and explicitly configured wrappers in regular terminals.

Native OSC 9 is a conditional future design note with no implementation work in the current scope. No Zed fork is required. Do not store credentials, SSH private configuration, or generated build artifacts in this repository.

## Design and status

The authoritative scope and initial architecture are recorded in [docs/initial-design.md](docs/initial-design.md). Production implementation has not started; the Mac helper, public window-object baseline, and lazy shell binding are the selected direction. The helper starts on demand and remains alive until the associated Zed app exits, including while individual project windows close. The race before the first focus query is accepted for now and will be revisited if observed in practical use. Detected capture changes or timeouts leave the cache empty and allow the command to proceed; local-hook integration remains to be implemented.

The [lightweight implementation plan](docs/implementation-plan.md) proposes working slices, with unit tests alongside each component and integration evidence guiding subsequent iterations.

Probe scripts, API alternatives, and outcome summaries are preserved in [experiments/macos-window-notifications](experiments/macos-window-notifications/README.md). The archive distinguishes tested approaches from prototypes and uses configurable runtime directories.
