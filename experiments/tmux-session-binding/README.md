# Local tmux session-binding probes

This is the first probe for the shared tmux session-publication mechanism. It tests one path only: from an eligible Zed terminal on macOS, use native `tmux a` selection to attach to one of two existing sessions and publish a synthetic context to the session tmux actually selected.

The probe does not capture a real Zed window or send notifications. Its `client-attached` hook is an experiment candidate, not a production decision. The remote AL2023 path, named attachment, session creation, `new -A`, detached delivery, and attachment ownership are outside this first probe.

## Isolation and safety

- Every probe command addresses a unique tmux socket label with `-L`; it does not use the default socket or your existing sessions.
- The probe server starts with `/dev/null` as its configuration, so it does not load or change your tmux configuration.
- `prepare`, `attach`, and `inspect` require an interactive regular Zed terminal with `ZED_TERM=true`, without `ZED_NOTIFY_DISABLED=1`, and outside an existing tmux client.
- Runtime state is written under `.local/tmux-session-binding/`. The script refuses to prepare unless that path is excluded from version control.
- `stop` verifies the run marker, refuses while a client is attached, asks for confirmation, and targets only that run's socket. It leaves the local run record in place.

## Run the probe

From a regular Zed integrated terminal, prepare the isolated server:

```zsh
zsh experiments/tmux-session-binding/probe-local-default-attach.zsh prepare
```

The script prints a run directory. Copy that path and attach from the same eligible terminal:

```zsh
zsh experiments/tmux-session-binding/probe-local-default-attach.zsh attach /path/printed/by/prepare
```

This invokes `attach-session` without a target, so tmux makes its native selection. The isolated `client-attached` hook runs `set-option` without an explicit target; the probe checks whether tmux scopes it to the attached session. The command stays attached.

While it is attached, use a second eligible Zed terminal to inspect the result:

```zsh
zsh experiments/tmux-session-binding/probe-local-default-attach.zsh inspect /path/printed/by/prepare
```

`PASS` means exactly one client is attached, its selected session has the synthetic context, and the other session retains its original sentinel. `FAIL` or `INCONCLUSIVE` is evidence to record; it is not a reason to modify the user's tmux setup.

After recording the output, detach the probe client with the probe server's default prefix (`Ctrl-b`, then `d`). Stop the isolated server when no clients remain:

```zsh
zsh experiments/tmux-session-binding/probe-local-default-attach.zsh stop /path/printed/by/prepare
```

The run directory remains under `.local/` as local runtime evidence. Record only synthetic outcome summaries in this shareable experiment directory.

## Observed result

**PASS on the tested local macOS tmux setup.** Native default attach selected the right-hand test session. The `client-attached` hook set that session's `@zed_notify_context` to the synthetic probe context, while the left-hand session retained its sentinel. The isolated server was stopped after inspection.

This confirms the session binding behavior for this local default-attach path. It does not validate the remote AL2023/SSH path or notification delivery.

See [RESULTS.md](RESULTS.md) for the redacted operator transcript, including setup failures, diagnostics, the passing rerun, and cleanup.

## Implementation notes from the probe

- Pass the unique session name directly to `-t`. In the tested tmux setup, prefixing it with `=` was treated literally and failed to find the session.
- Do not use `#{hook_session}` as the `-t` value in this hook. tmux treated it literally and reported `No such session: #{hook_session}`. Omitting `-t` let the hook's attached-session context scope `set-option`; the rerun confirmed the selected session changed and the other did not.
- A parse error near `;;` was reported after cleanup, but a subsequent `zsh -n` check of the current script emitted no diagnostics. The syntax error was not reproduced, and no syntax fix was needed.

## Probe 2: first-session creation

This probe tests one path on local macOS tmux: create and attach to the first session on a fresh, isolated socket, with the `after-new-session` hook loaded before the server and session start. It checks whether that new session receives the synthetic context while the client remains attached.

“First session” means first session on the probe's unique socket. It does not require stopping the regular macOS or AL2023 tmux servers. `prepare` reserves the socket and writes a private runtime config without starting a server; `create` starts only that isolated server and invokes `new-session` without `-d` or a session name.

Prepare from a regular Zed integrated terminal:

```zsh
zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh prepare
```

Copy the printed run directory and run the printed `create` command from the eligible Zed terminal. It creates and attaches to the first session, then remains attached until detached.

While it is attached, inspect from a second eligible Zed terminal:

```zsh
zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh inspect /path/printed/by/prepare
```

`PASS` means the isolated socket has exactly one session and one attached client, and that session has the synthetic probe context. `FAIL` or `INCONCLUSIVE` is evidence to record; it is not a reason to modify the user's tmux setup.

After recording the output, detach with the probe server's default prefix (`Ctrl-b`, then `d`). Stop the isolated server when no clients remain:

```zsh
zsh experiments/tmux-session-binding/probe-local-first-session-create.zsh stop /path/printed/by/prepare
```

This probe does not test named creation, `new -A`, remote AL2023 tmux, notification delivery, or attachment ownership. Record its outcome in `RESULTS.md` after operator execution.
