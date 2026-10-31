# Zed Terminal Command Notifications

A small, version-controlled project for notifying on the Mac when long-running foreground commands finish inside remote interactive Zsh sessions, especially AL2023 shells running in tmux and viewed through Zed.

## Primary workflow

The target flow is Zed terminal on macOS → interactive SSH → remote tmux → interactive Zsh pane. A Zsh hook in each remote pane measures foreground command duration and exit status. Notifications should arrive on the Mac while the SSH and tmux sessions remain attached.

## Current findings

- A local Zsh hook only sees the SSH process and therefore reports when the session ends, not when a command in a remote pane finishes.
- The command-completion hook belongs on the remote host and must load in each interactive Zsh pane.
- The native terminal route is for the remote hook to emit OSC 9 through SSH and tmux to the local terminal. Tmux passthrough must be configured where needed.
- Zed's regular terminal does not currently document OSC 9 notification handling; see the upstream request: https://github.com/zed-industries/zed/discussions/47726.
- A Mac-side notification bridge over an SSH reverse forward is a possible workaround, but adds a local helper and transport setup.
- A Zed-origin environment marker is optional. If used, it must be forwarded by SSH and made available to tmux panes; it is not required for the hook to detect command completion.

## Initial scope

Track the remote hook, notification transport, Zed protocol dependency, and validation across plain SSH shells and remote tmux panes. Do not store credentials, SSH private configuration, or generated build artifacts in this repository.

## Design and status

The prospective architecture and alternatives are recorded in [docs/prospective-design.md](docs/prospective-design.md). The initial implementation is not started; the main open choice is native OSC 9 support in Zed versus a Mac-side notification bridge.
