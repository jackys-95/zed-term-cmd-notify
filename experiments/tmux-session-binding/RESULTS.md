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
- `<RUN_1>` through `<RUN_5>` replace generated probe run IDs. `<SOCKET_1>` through `<SOCKET_5>` replace isolated socket labels.
- `<PROBE_TTY>` and `<INSPECTOR_TTY>` replace terminal device names.
- `<TIME>` replaces recorded clock times in the message log; entries retain their original order.
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

## First-session creation probe

**PASS after changing the hook candidate to `after-new-session`.** The first attempt used `client-attached`; the new session had no `@zed_notify_context`. A fresh run loaded `after-new-session` before starting the isolated server, and inspection found the expected synthetic context on the first session.

The fresh run's `create` command returned with tmux reporting that the client was detached. Its first inspection was therefore inconclusive because there were no attached clients. The operator then attached to session `0` on the isolated socket; inspection from a second terminal found exactly one attached client and the expected context. The isolated server was stopped after the passing inspection.

The transcript below preserves the first attempt's supplied prepare, inspect, and diagnostic inputs and outputs.

Preparation selected a fresh isolated socket without starting a server:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh prepare
Probe run: <REPO_ROOT>/.local/tmux-session-binding/<RUN_4>
Reserved an unused isolated socket label: <SOCKET_4>
No tmux server was started by prepare.

Next, run this from the eligible Zed terminal:
  zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-first-session-create.zsh create <REPO_ROOT>/.local/tmux-session-binding/<RUN_4>
The create command starts the first server/session on this socket and stays attached until detached.
```

Inspection from a second terminal found one attached client on the first session, but the context was empty:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh inspect .local/tmux-session-binding/<RUN_4>
Probe sessions: 1
  0
Attached client sessions: 1
  0
Initial session context:
FAIL: the first created session did not receive the expected context.
```

The server had loaded the configured `client-attached` hook:

```console
[shell prompt redacted] % probe_socket=<SOCKET_4>
[shell prompt redacted] % tmux -N -L "$probe_socket" show-hooks -g client-attached
client-attached[0] set-option -F @zed_notify_context local-probe-<RUN_4>
```

The attached client's message log contained the probe creation command and the read-only inspection commands. Terminal device names are redacted:

```console
[shell prompt redacted] % tmux -N -L "$probe_socket" show-messages -t "$(tmux -N -L "$probe_socket" list-clients -F '#{client_name}')"
<TIME>: <INSPECTOR_TTY> command: show-messages -t <PROBE_TTY>
<TIME>: <INSPECTOR_TTY> command: list-clients -F "#{client_name}"
<TIME>: <INSPECTOR_TTY> command: show-hooks -g client-attached
<TIME>: <INSPECTOR_TTY> command: show-options -qv -t 0 @zed_notify_context
<TIME>: <INSPECTOR_TTY> command: list-clients -F "#{client_session}"
<TIME>: <INSPECTOR_TTY> command: list-sessions -F "#{session_name}"
<TIME>: <INSPECTOR_TTY> command: show-options -qsv @zed_notify_probe_run
<TIME>: <PROBE_TTY> command: new-session
```

Before stopping the isolated server, the operator retried `create` on the same run. Its output still identified the `client-attached` hook, so it used the pre-revision script. After detaching, Zsh also reported `command not found: sac` at the script's line 262:

```console
[shell prompt redacted] % zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-first-session-create.zsh create <REPO_ROOT>/.local/tmux-session-binding/<RUN_4>
Starting the first session on the isolated socket with tmux new-session.
The isolated client-attached hook will publish: local-probe-<RUN_4>
[detached (from session 0)]
<REPO_ROOT>/experiments/tmux-session-binding/probe-local-first-session-create.zsh:262: command not found: sac
```

The operator then stopped the isolated server:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh stop .local/tmux-session-binding/<RUN_4>
Stop only the isolated probe server on '<SOCKET_4>'? [y/N] y
Stopped the isolated probe server. Runtime evidence remains in <REPO_ROOT>/.local/tmux-session-binding/<RUN_4>.
```

### Fresh run: `after-new-session` passed

Preparation reserved a new isolated socket without starting a server:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh prepare
Probe run: <REPO_ROOT>/.local/tmux-session-binding/<RUN_5>
Reserved an unused isolated socket label: <SOCKET_5>
No tmux server was started by prepare.

Next, run this from the eligible Zed terminal:
  zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-first-session-create.zsh create <REPO_ROOT>/.local/tmux-session-binding/<RUN_5>
The create command starts the first server/session on this socket and stays attached until detached.
```

The operator ran the printed `create` command. It reported the updated hook, then returned detached:

```console
[shell prompt redacted] % zsh <REPO_ROOT>/experiments/tmux-session-binding/probe-local-first-session-create.zsh create <REPO_ROOT>/.local/tmux-session-binding/<RUN_5>
Starting the first session on the isolated probe socket with tmux new-session.
The isolated after-new-session hook will publish: local-probe-<RUN_5>
[detached (from session 0)]
```

The first inspection was inconclusive because the session had no attached client:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh inspect .local/tmux-session-binding/<RUN_5>
Probe sessions: 1
  0
Attached client sessions: 0
INCONCLUSIVE: inspect while exactly one probe client is attached.
```

The operator then attached to the only session on the isolated socket. The command was:

```console
tmux -L <SOCKET_5> attach-session -t 0
```

Inspection from a second eligible terminal passed:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh inspect .local/tmux-session-binding/<RUN_5>
Probe sessions: 1
  0
Attached client sessions: 1
  0
Initial session context: local-probe-<RUN_5>
PASS: the first created session received the probe context while attached.
```

After detaching the client, the operator stopped the isolated server:

```console
[shell prompt redacted] % zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh stop .local/tmux-session-binding/<RUN_5>
Stop only the isolated probe server on '<SOCKET_5>'? [y/N] y
Stopped the isolated probe server. Runtime evidence remains in <REPO_ROOT>/.local/tmux-session-binding/<RUN_5>.
```
