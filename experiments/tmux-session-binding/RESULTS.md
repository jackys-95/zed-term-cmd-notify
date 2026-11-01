# Local tmux default-attach probe results

## Scope

This records the operator-run probe on a local macOS tmux setup. It used two detached sessions, tmux's native default `attach-session` selection, and a synthetic session option set by a global `client-attached` hook.

## Outcome

**PASS after correcting two probe setup issues.** Native default attach selected the right-hand test session. The hook set that session's `@zed_notify_context` to the synthetic probe context; the left-hand session retained its sentinel. The isolated server was stopped after inspection.

The first run failed during setup because the probe prefixed an exact session name with `=`. The second run attached, but its hook command used `#{hook_session}` as a `-t` target; tmux treated that string literally and did not update either session. The final run passed after removing both forms of target syntax: setup and inspection use the unique session names directly, and the hook omits `-t` so `set-option` uses the attached-session context.

This result covers only local macOS default attach and session-option binding. It does not validate SSH, AL2023, notification delivery, named attachment, session creation, `new -A`, or detached delivery.

## Redactions

- `[shell prompt redacted]` replaces the shell prompt, including user and host.
- `<REPO_ROOT>` replaces the absolute repository path and its home-directory prefix. It is a transcript placeholder, not a shell variable.
- `<RUN_1>`, `<RUN_2>`, and `<RUN_3>` replace generated probe run IDs. `<SOCKET_1>`, `<SOCKET_2>`, and `<SOCKET_3>` replace isolated socket labels.
- `<PROBE_TTY>` and `<INSPECTOR_TTY>` replace terminal device names.
- Session names, sentinel values, and context values retain their synthetic labels, with their generated run suffix replaced by the corresponding `<RUN_n>`.

## Operator transcript

The blocks below preserve the recorded terminal inputs and outputs, with the redactions above applied.

### Run 1: setup failed on the session target

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-default-attach.zsh prepare
Probe run: <REPO_ROOT>/.local/tmux-session-binding/<RUN_1>
Starting an isolated tmux server on socket label: <SOCKET_1>
no such session: =zed-notify-probe-left-<RUN_1>
```

The probe was changed to pass its unique session names directly as `-t` targets, without the `=` prefix.

The partial isolated server was then stopped:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-default-attach.zsh stop <REPO_ROOT>/.local/tmux-session-binding/<RUN_1>
Stop only the isolated probe server on '<SOCKET_1>'? [y/N] y
Stopped the isolated probe server. Runtime evidence remains in <REPO_ROOT>/.local/tmux-session-binding/<RUN_1>.
```

### Run 2: attach succeeded, but the hook target did not

Preparation succeeded:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-default-attach.zsh prepare
Probe run: <REPO_ROOT>/.local/tmux-session-binding/<RUN_2>
Starting an isolated tmux server on socket label: <SOCKET_2>

Prepared two detached sessions with distinct sentinel contexts.
Next, run this from the eligible Zed terminal:
  zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh attach <REPO_ROOT>/.local/tmux-session-binding/<RUN_2>
The attach command uses native default selection and will block until detached.
```

The operator attached, then inspected from a second eligible terminal:

```console
[shell prompt redacted] % zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh inspect <REPO_ROOT>/.local/tmux-session-binding/<RUN_2>
Attached client sessions: 1
  zed-notify-probe-right-<RUN_2>
Session context values:
  zed-notify-probe-left-<RUN_2>: untouched-left-<RUN_2>
  zed-notify-probe-right-<RUN_2>: untouched-right-<RUN_2>
FAIL: the actual selected session did not receive the expected context, or the other session changed.
```

The stored hook was present:

```console
[shell prompt redacted] % tmux -N -L <SOCKET_2> show-hooks -g client-attached
client-attached[0] set-option -F -t "#{hook_session}" @zed_notify_context local-probe-<RUN_2>
```

The operator read the attached client's message log:

```console
[shell prompt redacted] % tmux -N -L <SOCKET_2> show-messages -t "$(tmux -N -L <SOCKET_2> list-clients -F '#{client_name}')"
<TIME>: <INSPECTOR_TTY> command: show-messages -t <PROBE_TTY>
<TIME>: <INSPECTOR_TTY> command: list-clients -F "#{client_name}"
<TIME>: <INSPECTOR_TTY> command: show-hooks -g client-attached
<TIME>: <INSPECTOR_TTY> command: show-options -qv -t zed-notify-probe-right-<RUN_2> @zed_notify_context
<TIME>: <INSPECTOR_TTY> command: show-options -qv -t zed-notify-probe-left-<RUN_2> @zed_notify_context
<TIME>: <INSPECTOR_TTY> command: list-clients -F "#{client_session}"
<TIME>: <PROBE_TTY> key MouseDrag1Pane: copy-mode -M
<TIME>: <PROBE_TTY> key MouseDrag1Pane: if-shell -F "#{||:#{pane_in_mode},#{mouse_any_flag}}" { send-keys -M } { copy-mode -M }
<TIME>: <PROBE_TTY> key MouseDown1Pane: send-keys -M
<TIME>: <PROBE_TTY> key MouseDown1Pane: select-pane -t =
<TIME>: <PROBE_TTY> message: No such session: #{hook_session}
<TIME>: command: set-option -F -t "#{hook_session}" @zed_notify_context local-probe-<RUN_2>
<TIME>: <PROBE_TTY> command: attach-session
<TIME>: <PROBE_TTY> command: show-options -qsv @zed_notify_probe_run
<TIME>: <PROBE_TTY> command: set-hook -g client-attached "set-option -F -t \"#{hook_session}\" @zed_notify_context \"local-probe-<RUN_2>\""
<TIME>: <PROBE_TTY> command: set-option -t zed-notify-probe-right-<RUN_2> @zed_notify_context untouched-right-<RUN_2>
<TIME>: <PROBE_TTY> command: set-option -t zed-notify-probe-left-<RUN_2> @zed_notify_context untouched-left-<RUN_2>
<TIME>: <PROBE_TTY> command: new-session -d -s zed-notify-probe-right-<RUN_2>
<TIME>: <PROBE_TTY> command: set-option -s @zed_notify_probe_run <RUN_2>
<TIME>: <PROBE_TTY> command: new-session -d -s zed-notify-probe-left-<RUN_2>
```

The `No such session: #{hook_session}` message confirmed that tmux treated the format string literally in the target position. The hook was changed to omit `-t`; the rerun tests whether the hook's attached-session context scopes the option correctly.

The operator detached and stopped this isolated server:

```console
[shell prompt redacted] % zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh attach <REPO_ROOT>/.local/tmux-session-binding/<RUN_2>

Attaching with tmux's native default target selection.
The isolated client-attached hook will publish: local-probe-<RUN_2>
[detached (from session zed-notify-probe-right-<RUN_2>)]
Stop only the isolated probe server on '<SOCKET_2>'? [y/N] y
Stopped the isolated probe server. Runtime evidence remains in <REPO_ROOT>/.local/tmux-session-binding/<RUN_2>.
<REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh:277: parse error near `;;'
[shell prompt redacted] %
```

A subsequent syntax-only check of the current script was silent:

```console
[shell prompt redacted] % zsh -n <REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh
```

Observed output: no output. No syntax error was reproduced, and no syntax fix was needed.

### Run 3: corrected probe passed

Preparation succeeded:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-default-attach.zsh prepare
Probe run: <REPO_ROOT>/.local/tmux-session-binding/<RUN_3>
Starting an isolated tmux server on socket label: <SOCKET_3>

Prepared two detached sessions with distinct sentinel contexts.
Next, run this from the eligible Zed terminal:
  zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh attach <REPO_ROOT>/.local/tmux-session-binding/<RUN_3>
The attach command uses native default selection and will block until detached.
```

The operator attached using the printed command, left the probe client attached, and inspected from a second terminal:

```console
[shell prompt redacted] % zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh inspect <REPO_ROOT>/.local/tmux-session-binding/<RUN_3>
Attached client sessions: 1
  zed-notify-probe-right-<RUN_3>
Session context values:
  zed-notify-probe-left-<RUN_3>: untouched-left-<RUN_3>
  zed-notify-probe-right-<RUN_3>: local-probe-<RUN_3>
PASS: the actual selected session received the probe context; the other session is unchanged.
```

The operator detached and stopped the isolated server:

```console
[shell prompt redacted] % zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh attach <REPO_ROOT>/.local/tmux-session-binding/<RUN_3>

Attaching with tmux's native default target selection.
The isolated client-attached hook will publish: local-probe-<RUN_3>
[detached (from session zed-notify-probe-right-<RUN_3>)]
[shell prompt redacted] % zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-default-attach.zsh stop <REPO_ROOT>/.local/tmux-session-binding/<RUN_3>
Stop only the isolated probe server on '<SOCKET_3>'? [y/N] y
Stopped the isolated probe server. Runtime evidence remains in <REPO_ROOT>/.local/tmux-session-binding/<RUN_3>.
```
