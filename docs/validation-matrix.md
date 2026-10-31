# Validation Matrix

| Session | Hook location | Expected notification point | Status |
| --- | --- | --- | --- |
| Remote interactive Zsh over SSH, no tmux | Remote `~/.zshrc` | After a long foreground command returns to the prompt | Not implemented |
| Remote tmux pane running interactive Zsh | Remote `~/.zshrc` | After a long foreground command in that pane returns to the prompt | Not implemented |
| Local SSH process completion | Local `~/.zshrc` | When SSH exits or detaches; insufficient for per-command remote alerts | Known limitation |
| Remote shell emits OSC 9 through SSH and tmux | Remote hook plus tmux passthrough | Local terminal receives the sequence | Blocked on Zed regular-terminal support |
| Remote hook sends event to Mac helper | Remote hook plus forwarded local listener | Mac helper creates a macOS notification | Design option; not implemented |

The hook should ignore short commands, report the remote exit status, and avoid treating a command stopped by Ctrl-C as a successful completion. Background jobs and commands started in detached tmux panes need separate behavior decisions.
