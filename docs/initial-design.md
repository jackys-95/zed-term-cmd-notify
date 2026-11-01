# Initial Design: Zed Terminal Command Notifications

**Status:** Scope, Mac-side notification helper, and public Accessibility window-object baseline approved; production implementation has not started. Mac-only probes have demonstrated notification delivery, source-window focus, minimized-window restoration, and closed-window rejection.

**Last reviewed:** 2026-11-01.

## Purpose

This document defines the scope for silent macOS notifications when long-running foreground commands finish in interactive Zsh sessions used through Zed's regular integrated terminal. It covers ordinary local shells, local tmux panes, plain SSH shells, and remote tmux panes. All four workflows use a Mac-side helper and associate each notification with its source Zed window. AL2023 is the initial Linux target for the remote workflow.

The approved implementation direction uses Zsh command hooks, a Rust local client, and a Swift helper for native macOS notifications and window APIs. Remote delivery adds a Rust SSH launcher and a small prebuilt Rust event sender. Local and remote tmux share session-binding behavior while using their respective delivery paths. Native OSC 9 is a conditional future alternative only. It has no implementation, configuration, or test work in the current scope, and the project does not require a Zed fork.

## Problem and goals

Long-running commands can finish while their source Zed window or tmux pane is hidden. The user needs a silent completion notification that distinguishes the source window from another foreground Zed window and returns to the source on click. Completion detection belongs in the interactive Zsh shell running the command.

A local shell hook reports completion through the Rust local client to the Mac helper, using the same detection and delivery path inside local tmux. Ordinary shells retain their original window association; persistent tmux panes need a session binding that can change when the user detaches and reattaches in another window. Tmux integration manages that current association, and the Zsh hooks inside its panes report command completion.

For remote commands, the local Zsh process sees the interactive SSH connection as one foreground command. Its `precmd` hook runs when SSH returns control, such as after logout or detach, so it cannot report individual remote completions while the connection remains open. Hooks in the remote shells send those events through the active SSH notification connection.

The first version includes foreground commands in local interactive Zsh shells in Zed's regular integrated terminal, associated local tmux sessions, plain remote interactive Zsh over SSH from that terminal, and associated remote tmux sessions while their notification connections are active. Every interactive Zsh pane in an associated tmux session is covered, including hidden panes. Delivery while local tmux is detached remains an open policy decision. A pager, TUI, or REPL remains active until it exits and returns control to Zsh.

Terminal Threads are excluded from both workflows for now because the user generally uses them for agent harness sessions. Their existing notification behavior is separate from this project.

The notification should include elapsed time, exit status, host, and applicable session or pane context without command text or sensitive paths. Clicking should focus the exact source Zed window. Navigating to the exact terminal or tmux pane is outside the current scope.

Background jobs, delivery of events completed while no remote notification connection is available, durable event queues, replay, automatic reconnect, other shells, and other terminal applications are outside the first version. A foreground tmux command may span a disconnect and notify if the user reconnects and reattaches before it finishes.

## Notification policy

Zsh functions registered through `add-zsh-hook` measure a command from `preexec` to `precmd`, alongside existing hooks. Capture the exit status immediately on entry to the completion hook, before other operations change it. Commands lasting at least 30 seconds qualify for a notification immediately on completion; there is no additional 30-second delay. The same threshold applies to success and failure. The approved interruption baseline suppresses exit status 130 as a heuristic rather than introducing a global signal trap.

Notifications are silent. With a valid source association, the helper suppresses a notification when that particular Zed window is foreground. Another Zed window being foreground does not suppress it. The duration threshold remains the minimum policy if source-window filtering cannot be established reliably; handling and presentation of that fallback need to be defined before implementation.

## Terminal eligibility and harness exclusions

Mac-side eligibility is an explicit gate: require `ZED_TERM=true` and reject `ZED_NOTIFY_DISABLED=1`. Ordinary local command hooks check it at each command launch, local tmux entry integration checks the attaching terminal before establishing a session binding, and the SSH launcher checks it at startup. Perform these checks before starting the helper, capturing a source window, registering work, or setting up a notification forward. Hooks may be installed in the shared Mac `~/.zshrc`; loading them does not make every terminal eligible. Commands, tmux entry, and ordinary SSH continue when the gate rejects notification setup.

| Mac terminal environment | Notification eligibility |
| --- | --- |
| Zed regular integrated terminal: `ZED_TERM=true`, opt-out unset | Eligible, subject to the command denylist |
| Configured Zed Terminal Thread: `ZED_TERM=true`, `ZED_NOTIFY_DISABLED=1` | Excluded |
| Ordinary iTerm2, cmux, or macOS Terminal session: Zed marker absent | Excluded |

The approved Terminal Thread exclusion is an explicit opt-out flag. Configure `agent.terminal_init_command` to export `ZED_NOTIFY_DISABLED=1` before any existing initialization command. This uses an existing Zed setting and requires no Zed source change. Existing running threads need the export applied or must be restarted. The local hooks and SSH launcher must honor the flag so that the thread remains excluded after its harness exits, and command execution can continue without notification setup.

The exported flag can also exclude inherited child-shell environments. It identifies notification eligibility, not a source window. `ZED_TERM=true` remains a Zed-origin signal shared by both terminal surfaces; the explicit Terminal Thread initialization is what establishes the exclusion in the configured workflow. Installation must account for existing initialization commands rather than replacing them with a different harness.

Remote hooks require an active bridge association established by an eligible Mac-side launcher; they do not require `ZED_TERM` to be forwarded over SSH. An unassociated remote shell must not emit bridge notifications. Environment eligibility establishes the allowed terminal workflow; source-window capture separately establishes which Zed window owns the work.

Local tmux pane hooks require a session binding established from an eligible attaching terminal. A surviving pane's inherited Zed marker cannot establish the eligibility or window association of a later attachment. Pane hooks retain command exclusions and the explicit opt-out; an unassociated local tmux session must not emit notifications. The attachment ownership policy below must define how entry from an excluded terminal affects an existing binding.

A separate, bounded denylist suppresses harness-session completion alerts for Codex, Claude, and Pi, including when launched in regular integrated terminals. Initial coverage includes direct invocations and simple aliases expanded by Zsh's `preexec` arguments. Functions and scripts that wrap a harness require explicit wrapper-name entries or an opt-out flag; arbitrary wrapper interpretation and continuous process monitoring are outside scope. Match invoked commands rather than unrelated mentions of harness names in arguments.

Resolving executable paths alone is insufficient in the inspected setup: Codex and Claude both resolve through a shared executable launcher, and Pi uses a Node script. Denying all commands using those shared launchers or runtimes would exclude unrelated work. The denylist supplements the session flag and does not independently distinguish Terminal Threads.

## Source-window capture

The ordinary local workflow outside tmux uses lazy binding once per shell session. The user confirmed that an existing integrated terminal stays in its original Zed window for the shell's lifetime; moving that terminal between windows is outside this baseline. A local tmux session can detach and reattach in another window while its pane shells survive, so its panes use the shared session binding described below. Shell initialization installs hooks but performs no source capture or helper startup. This avoids capture requests from terminals restored together.

Capture happens on the first eligible interactive command while its source window is foreground. The helper retains the actual Accessibility window object and returns an opaque token. The shell stores that token in a non-exported variable for reuse between commands; the object itself remains in Swift. A fresh or restored shell starts with an empty cache, and child shells establish their own association.

| Workflow | Capture point | Association lifetime |
| --- | --- | --- |
| Local interactive commands outside tmux | First eligible local `preexec` when the shell has no cached association | Reuse the shell's token while available; retain each command's original association through completion and notification handling |
| Persistent local tmux commands | Capture in the eligible attaching terminal before tmux entry; select the session's current binding when a qualifying command finishes | Reattachment or session-wide manual rebind replaces the binding for future completions; each issued notification retains its original association |
| Plain remote interactive commands | Mac-side launcher startup in the source Zed window, before SSH starts | Associate events with that SSH connection's captured window |
| Persistent remote tmux commands | Capture the connection window at launcher startup; select the session's current connection when a qualifying command finishes | Manual reconnect and reattachment replace the session route; each issued notification retains the window associated with the route used for delivery |

Once bound, subsequent ordinary local command launches only check eligibility and exclusions, save their original token, and record timing in Zsh. They do not invoke the Rust client or query Accessibility. Qualifying completion events use a short-lived Rust IPC client to report the token, duration, and exit status to Swift, which checks source foreground state and handles notification delivery. Local tmux panes use the same client and delivery path, resolving the session's current token at qualifying completion. A separate persistent Rust process is not required by this binding design.

An initial capture request waits for an acknowledgment with a bounded timeout; command execution proceeds if capture fails. Leave the cache empty after a failed capture so a later eligible command can retry. When the helper reports a stale token, clear it and attempt fresh capture at a later eligible command launch. Never recapture at command completion or notification click, when another window may be foreground. Helper restart loses its retained objects; closing the source invalidates its object. Handling delivery with an unavailable association remains part of the fallback decision below.

Manual rebinding is approved, with `zed-notify rebind` as the proposed command spelling. Run it from the affected integrated terminal while its intended Zed window is foreground. A valid association to the wrong window is not necessarily detectable, so automatic stale-token recovery does not replace this explicit recovery action. Rebinding uses the same bounded capture checks and accepted initial attribution limitation.

For an ordinary local shell outside tmux, a Zsh function must handle the rebind action in the calling shell so it can clear the non-exported cache and store a fresh token returned by the Rust client. An external executable alone cannot update that shell variable. Exclude this maintenance action from ordinary command notification tracking. Report success or failure in the invoking terminal; failed local rebinding leaves the cache empty for a later eligible command to retry. Already launched ordinary local commands keep their original tokens, and issued notifications keep their original associations.

For local tmux, manual rebind captures the intended foreground Zed window through the local client and replaces the session binding shared by all panes. It must validate the eligible attachment context rather than authorize capture from inherited pane markers alone. Failed rebinding marks the session association unavailable rather than keeping a known suspect token; recovery is an explicit retry or eligible reattachment. A command still running during rebind uses the current session binding at completion. Already issued notifications keep their original associations. Local rebinding requires no SSH connection registration or forwarding.

For a plain remote shell or associated tmux pane, manual rebinding sends an explicit control request through the existing reverse forward to recapture the current connection's Mac window association. Resolve the current tmux session route when applicable; do not use a pane's inherited stale connection environment. Rebinding affects the connection, including other sessions routed through it, rather than establishing a separate window binding per pane. The request must require an active registered connection, return a bounded success or failure response, and never create a new SSH connection. Failed remote rebinding must mark that connection's source association unavailable rather than silently keep a known suspect association. Recovery after connection loss remains manual reconnect and reattachment. Future remote completions use the current route and its updated association; issued notifications retain their original captured objects.

Tmux pane hooks use an already captured session context; they do not capture whichever Mac window is foreground when a command starts or finishes. Local panes select the session's current helper token, and remote panes select its currently registered connection, at qualifying completion. Plain remote shells use their SSH connection's association. Once an event is delivered and a notification is issued, its association remains fixed so later commands, rebinds, or reconnects cannot redirect that notification.

The approved baseline retains the public Accessibility window object for identity and control. Foreground checks require Zed to be the frontmost application and compare its current focused window object with the retained source object. Validate the source process and object before control; reject an invalid association rather than choosing another window.

The association does not depend on a saved rectangle, title, numeric WindowServer ID, or stacking order. Moving or resizing a window does not change the stored association; those cases still require integration validation. Window titles are diagnostic text and need not be unique.

## Mac-side architecture and session behavior

Local and remote hooks report to the same notification handling in the Swift helper. Local hooks invoke the short-lived Rust local client for binding and completion requests over local IPC. The helper uses native macOS notifications, requests notification authorization, handles clicks, and uses Accessibility permission for window inspection and control. It should not appear as a Dock application.

The approved helper lifetime follows the entire Zed app instance. Start the helper on demand when an eligible local shell first requests a binding, eligible local tmux entry requests a binding, or an eligible SSH launcher starts, then reuse it until that Zed app exits. Retain window objects and notification tokens throughout that app session. Closing a project window invalidates its association but does not stop the helper; it also stays alive if all windows close while Zed remains running. No login startup service or automatic daemon restart is required.

Observe `NSWorkspace.didTerminateApplicationNotification` through the workspace's notification center and compare the affected `NSRunningApplication` with the associated Zed app instance. Check that instance's `isTerminated` state after registering the observer to cover an exit during setup. On Zed app exit, discard retained associations and terminate the helper. A later Zed app session starts a fresh helper and creates fresh bindings; old tokens must not target that new session. Lifecycle detection remains to be implemented and tested.

A generic Rust launcher starts interactive SSH using the user's existing alias and SSH configuration. Remote completion events reach the Mac helper through a reverse forward in that same SSH connection. The bridge operates independently of any separate remote-command wrapper.

Concurrent remote connections need distinct routing and associated tmux sessions. Events from hidden panes in an associated remote session must use the same connection binding. Local tmux instead shares a helper window token across its panes and delivers through the local client.

## Persistent tmux sessions, attachment, and creation

Local and remote tmux share the attach/create integration, session-context lookup, and completion-time binding semantics. The common integration publishes the attaching terminal's notification context for the actual selected session. Local entry captures a helper window token in the eligible Mac terminal before attachment; remote entry receives a connection context from the SSH launcher's startup. Preserve both `tmux a`, which lets tmux choose a session, and `tmux a -t session-name`. Do not predict the default target independently or require an explicit session name for reattachment.

The session context distinguishes delivery paths. A local context references the Mac helper's window token and uses the ordinary local client. A remote context references the reverse-forward endpoint and registered SSH connection, whose helper registration owns the window association. Reuse the session-binding mechanism while keeping transport setup and validation specific to each path; local tmux requires no SSH launcher, reverse forward, Linux sender, or SSH connection registry.

New attached sessions must use the same registration path. Cover `tmux new`, `tmux new -s session-name`, and `tmux new -A -s session-name`, which attaches if the named session already exists and otherwise creates it. The user does not generally create detached sessions, so detached creation is not a required notification entry path in the first version.

Direct entry is a proposed convenience mode of the same Rust SSH launcher: establish the bridge, start remote interactive login Zsh with the connection context, and immediately invoke the same tmux attachment or creation integration. It must not introduce a separate notification mechanism or bypass the remote Zsh initialization. Detaching finishes this direct-entry SSH command while the tmux session remains running. CLI syntax for this mode has not been selected.

The proposed shared Zsh entry integration stores notification context in a session-specific custom tmux option, provisionally named `@zed_notify_context`. The exact local and remote context formats remain to be selected. It must preserve ordinary attachment and creation when notification setup is unavailable. Binding publication must happen as part of successful attachment or creation, before waiting for the interactive client to detach; simply updating state after the blocking tmux command returns would be too late. The exact tmux hook or command sequence for binding the actual selected session remains to be validated; no wrapper or tmux hook has been implemented.

Persistent servers and pane shells can outlive local attachment clients and SSH connections. Their existing process environments do not acquire replacement values on reattachment. Pane hooks therefore read current session state when a command qualifies at completion rather than relying on inherited tokens or endpoint variables, or snapshotting a session binding at command launch. Existing pane shells still need the Zsh hooks loaded once after installation; hidden panes use the same session state.

For local tmux, a command that starts with the session bound to window A and completes after eligible reattachment or manual rebind to window B uses B's current token. The elapsed time covers the whole command. Ordinary local shells outside tmux continue to retain their launch-time tokens. Local tmux completions validate the helper token, including after helper restart or source-window closure; they must never recapture at completion.

The user approved delivery through a reattached connection as a bounded change. If a command starts under connection A, A disconnects, and the user reattaches to the same session through B before completion, send its qualifying event through B. Foreground suppression and click focus use B's already captured Zed window, even if B originated in a different window. The command's elapsed time still covers the whole run.

If remote completion occurs without an available registered connection, drop the event; do not retain it for replay. Reconnection refreshes the session route, but never rewrites an already issued notification. This requires current-route lookup at completion, not a queue, automatic reconnect, another SSH connection, or a persistent Rust service. A leftover option from a dead connection is insufficient for delivery; stale connection identifiers must be rejected.

Local delivery while detached remains undecided. Direct helper access can remain available after detach, so the remote unavailable-connection rule does not select local behavior. Choose either continued delivery to the retained valid binding or delivery only while an eligible attachment is active. The latter requires attachment-lifetime tracking. Neither choice introduces queued events or replay.

The session has one current notification context shared by its panes. Before implementing attachment ownership, decide which client controls that context when several clients attach simultaneously, how detach affects the selected owner, and how attachment from an excluded terminal affects an existing eligible binding. Do not assume that publishing the latest context alone resolves those cases.

## Hook installation and delivery failures

Local hooks load in the Mac's interactive Zsh environment, normally through `~/.zshrc`, including tmux panes, and enforce the eligibility rules above. Remote hooks likewise load in each interactive Zsh shell or pane through remote `~/.zshrc`. Existing local and remote shells need to source the hook or restart after installation. Restored ordinary local shells defer binding until their first eligible interactive command; local tmux panes resolve an explicitly established session binding. The environment gate supplies no source-window identity.

Local completion requests use the Rust local client with bounded connection and delivery deadlines. An unavailable helper or failed request must preserve the command's exit status and allow the prompt to return. Ordinary local binding recovery and local tmux session recovery follow the distinct rules above.

The approved remote sender is a short-lived Rust executable invoked by the Zsh completion hook. It sends one completion event to the registered loopback endpoint through the SSH reverse forward, then exits. Build a Linux binary for the remote host's architecture and copy it alongside the remote Zsh scripts; AL2023 does not need Rust or Cargo installed. No remote sender daemon is required. Connection and delivery attempts must have bounded deadlines, and sender failure must preserve the command's exit status and allow the prompt to return. The event protocol, build target, and concrete deadline remain to be selected and validated.

The baseline requires manual reconnect and introduces no always-running daemon or replay service. If notification setup fails, SSH should still proceed with a clear indication that notifications are unavailable. Local command execution and tmux attachment must likewise proceed when the helper is unavailable. Hooks around the remote launcher or local tmux entry must not treat SSH exit or tmux detach as an individual pane command completion.

### SSH disconnect cleanup

Local terminal cleanup after the launcher's SSH process exits is approved. The user's laptop can lose connectivity or sleep while attached to remote tmux, leaving mouse-reporting modes enabled after an abrupt disconnect. Before returning control to the local shell, the launcher must disable the common mouse-reporting modes on its interactive terminal and restore any terminal settings it changed. Apply the same cleanup to normal SSH exit and disconnect failures, preserving the SSH result even if cleanup fails. Prefer targeted mode cleanup over automatically running a full `reset`, and preserve terminal contents. This requirement covers connections started through the launcher; it does not introduce a general shell hook for arbitrary SSH commands.

On 2026-11-01, the user supplied this remote `~/.config/tmux/tmux.conf`:

```tmux
# Enable mouse support
set -g mouse on

# Use Vim keybindings in copy mode
set-window-option -g mode-keys vi

set -g remain-on-exit on

set -g set-clipboard on
```

The user reports intrusive input after unexpected SSH disconnects and currently runs `reset` to recover. The supplied screenshot includes mouse-report fragments such as `0;18;10M` and `32;3;17M`. Enabled tmux mouse support is the likely source of those reports; the specific Zed/SSH reproduction has not yet been tested. The other supplied settings are not implicated by this evidence. A matching [tmux disconnect report and maintainer explanation](https://github.com/tmux/tmux/issues/2616#issuecomment-801300302) describes the remote client being unable to disable mouse reporting after the connection drops. [Xterm's mouse protocol documentation](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Extended-coordinates) describes the semicolon-separated coordinates and `M`/`m` event suffixes. Preserve `mouse on` as the user's intended configuration; cleanup must allow mouse support to work normally after reattachment.

Cleanup runs when SSH exits. Sleep or a network interruption that leaves SSH running does not trigger cleanup by itself; no sleep watcher or additional connection-failure detector is included. Reconnection remains manual, and cleanup must not terminate the persistent remote tmux server, sessions, or pane commands. The cleanup sequence still needs validation in Zed.

Existing Rust subprocess and fake-SSH test utilities may be copied and adapted. Developing a shared library or general-purpose tooling for SSH multiplexing and connection reuse, or modifying a separate remote-command wrapper, is outside this project's scope.

## Approved public window-object baseline

Mac-only probes have demonstrated silent native notification delivery without a helper Dock icon and exact source-window focus across Spaces. The successful public control sequence retained the source Accessibility object, requested `AXMain` and `AXRaise`, activated Zed through AppKit, then repeated the window controls after activation. A repeat without source edits or a new Zed diff hook also succeeded. Zed exposed `AXFocused` as read-only in these tests. Probe delays remain diagnostic settings rather than an approved production latency.

The subsequent object-only probe used retained public Accessibility objects for identity, focused-object comparison, validity checks, and control, without numeric WindowServer IDs, geometry matching, stacking-order matching, or private API conversion. The user approved this as the production baseline after three successful tests:

- Clicking a notification focused the retained source window across Spaces.
- Clicking with the source minimized restored that same object and verified it as Zed's focused window. This test involved no source edits or new Zed diff hook.
- Closing a disposable source window invalidated its retained object. The click handler rejected it before requesting activation; Firefox stayed foreground and Zed remained running.

A narrowly scoped private-ID experiment also succeeded earlier: `_AXUIElementGetWindow` returned the same source ID on another Space and supported the public focus sequence. Retain that result as experiment history only. Private conversion, private focus and Space-switching APIs, and public geometry or stacking-order matching are outside the approved implementation baseline.

The user accepts the residual source-attribution race for now: if focus changes after command submission but before the helper's first focus query, it may capture and cache a different window. Direct private ID conversion would not recover the original command source. Reusing the shell association avoids repeating that race for subsequent commands, provided the initial binding was correct. Revisit attribution if the race is observed in practical use; no Zed core change or further attribution experiment is required in the current scope.

Keep capture prompt and verify that the foreground app and focused object remain consistent during the query. Reject detected focus changes or timeouts, leave the cache empty, retry at a later eligible command launch, and let the command proceed. These are failure-handling safeguards, not a solution to a switch completed before the first query. Do not claim guaranteed command-source attribution.

These results validate the Mac notification and window-control probes on the user's setup. They do not validate local Zsh integration, the Rust launcher, remote hooks, or end-to-end event delivery. No window identity method is yet established for arbitrary Zed window arrangements or restored background terminals.

Primary implementations checked: [Hammerspoon's retained window object and ID bridge](https://github.com/Hammerspoon/hammerspoon/blob/master/Hammerspoon/HSuicore.m), [Hammerspoon's focus sequence](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/window/window.lua), and [yabai's window focus implementation](https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c).

## Failure behavior and security

Missing hooks, unavailable helpers, lost remote forwards, and missing permissions should produce diagnosable notification failures while allowing commands and SSH sessions to continue. The helper must not guess another window when the original association is invalid, the window has closed, or its identity is ambiguous.

The discussion proposed concise terminal diagnostics during capture and qualifying completion, with repeated messages limited to once per failure state. Examples are a capture-unavailable message before the command proceeds and a delivery-failure message when it finishes. General diagnostic wording, rate limiting, and missing-association notification behavior remain pending approval; explicit manual rebind already requires a terminal success or failure result. The proposed bounded click-failure handling is a Mac helper diagnostic log and user-initiated rebind. Pushing asynchronous click errors back into the originating local or remote shell would require additional communication and is not included in the current design.

The hooks should preserve command exit status and report failures accurately, with exit status 130 suppressed under the baseline policy. Reconnects and detach events must not produce duplicate per-command alerts. No disconnected event replay is required.

The helper should validate and bound event payloads, strip control characters, and accept only events associated with registered work or connections. Remote listeners bind to loopback and receive events through the SSH-forwarded channel. Local IPC must restrict access to the intended local user. The bridge must not expose a public endpoint, store credentials, execute notification content, or open arbitrary links. Credentials and private SSH configuration remain outside the repository.

Keep raw experiment evidence containing device or session data outside version control, including recorded window titles, process and window identifiers, coordinates, timestamps, opaque tokens, and original local paths. Shareable experiment sources must not embed data from recorded runs. Use explicit runtime-directory configuration, synthetic unit-test data, and outcome summaries for repository records. The probe sources and observed outcomes are described in the [experiment README](../experiments/macos-window-notifications/README.md).

Keep third-party research snapshots, their accompanying licenses, and detailed research provenance outside the shareable repository. Record relevant findings in the design and experiment summaries.

## Conditional future alternative

Native OSC 9 delivery through SSH and tmux would require a handler in Zed's regular integrated terminal. The existing bell behavior for Terminal Threads does not establish that support. Retain this as a future design note only; the current implementation uses the Mac helper and carries no OSC 9 implementation work or Zed core changes.

## Validation plan

The approved [unit-test requirements](validation-matrix.md#unit-test-requirements) cover notification policy, eligibility, Zsh hooks, binding and recovery, routing, protocol failures, launcher cleanup, and Swift helper logic. Add applicable tests with each component and run the automated checks before its end-to-end validation. Use controlled clocks and fake external operations for deterministic tests; real tmux, transport, and macOS behavior still require integration validation.

Validate ordinary local interactive Zsh, local tmux panes, plain remote interactive Zsh, and remote tmux panes separately. Cover commands below, at, and above the threshold; success and failure; exit status 130; pagers, TUIs, and REPLs; hidden tmux panes; and helper unavailability. Confirm that hooks preserve exit status and notifications arrive only after completion.

For each path, verify suppression when the exact source window is foreground, notification delivery when another Zed window or application is foreground, and click focus across Spaces. Check original associations after later commands, concurrent connections, window movement or resizing, overlapping windows, minimized or closed windows, and helper restart. Use the approved public object baseline and reject invalid associations without selecting another window.

Ordinary local rebind validation must include a valid but incorrect cached association, successful replacement in the calling shell, failed capture leaving an empty local cache, and maintenance-command exclusion. Verify that previously launched ordinary local commands and issued notifications retain their original tokens. For remote rebinding, cover plain shells, current tmux route selection after reattachment, connection-wide association replacement, bounded failure responses, and rejection of stale or disconnected connections. Verify that future completions use the replacement association without retargeting already issued notifications.

Local tmux validation must cover attach/create publication for the actual selected session, existing and hidden panes, independent sessions, session-wide manual rebind, and a running command spanning detach and reattachment to another Zed window. Verify completion-time lookup of the replacement token, unchanged associations for issued notifications, failed rebind invalidation, stale-token rejection, helper restart, and exclusion of the enclosing tmux command's completion. Cover current attachment eligibility despite stale pane environments, simultaneous-client ownership, excluded-terminal attachment, and the selected detached-delivery policy. Ordinary local launch-time token tests apply outside tmux; tmux commands instead use the session context current at completion.

Remote validation must include new-pane hook loading, connection teardown, manual reconnect, distinct concurrent routing, and exclusion of SSH exit or detach from per-command alerts. Verify both manual attach forms, attached creation with default and explicit names, both branches of create-or-attach, and direct entry through the same integration. Cover registration of the actual native target before detachment, creation when no tmux server is running, failed entry without changing another session's route, persistent server and pane survival, and a command spanning disconnect and reattachment. Check delivery through the new connection window, dropping completions during the gap without replay, stale-route rejection, unchanged associations for already issued notifications, and independent session routing. The local path also needs validation that only intended Zed shells register and that a command launched without reliable foreground attribution is handled explicitly. Restore several terminals and confirm startup triggers no captures; verify first-command binding, token reuse without client or Accessibility calls on later launches, independent child-shell caches, failed capture retry, stale-token invalidation, and fresh binding on a later launch without redirecting older notifications.

Terminal cleanup checks must use the user's supplied tmux configuration with `mouse on` and cover normal SSH exit, abrupt connection loss, and sleep/wake followed by SSH exit while mouse reporting was active. Verify that mouse movement, clicks, and scrolling no longer insert mouse reports into the local prompt; terminal contents remain intact; any launcher-modified terminal settings are restored; and SSH exit status is preserved. Check cleanup failure without masking the SSH result, remote tmux survival, and subsequent manual reconnection with tmux mouse support working again. A still-running SSH process after wake must not trigger premature cleanup.

Eligibility checks must cover regular Zed terminals, ordinary iTerm2/cmux/macOS Terminal sessions, new/recreated/already-running Terminal Threads, flag inheritance, and preservation of an existing initialization command. Confirm that excluded commands and SSH sessions still run without helper startup, capture, or bridge setup, and that a remote shell without an active association emits no bridge notification. Command exclusions must cover direct harness invocations, expanded aliases, configured wrapper names, and ordinary commands that merely mention a harness name.

## Open decisions

Developer testing for remote tmux registration, terminal cleanup, protocol selection, deadlines, Linux builds, CLI behavior, and focus latency is tracked in the [developer testing checklist](validation-matrix.md#developer-testing-checklist). Extend that matrix with the local tmux obligations above before implementing the shared tmux slice. These engineering checks remain pending and do not resolve the policy decisions below.

- What capture timeout keeps initial binding and rebinding responsive?
- Which tmux entry mechanism reliably binds the actual selected or newly created session before detachment, including default selection, create-or-attach, and direct SSH entry?
- Should local tmux continue delivering to its retained valid window binding while detached, or require an active eligible attachment?
- Which attachment owns a session's notification context with simultaneous clients, and how do owner detach and attachment from an excluded terminal affect it?
- How should missing-association notification fallback and its terminal diagnostics behave when source filtering or exact click focus is unavailable?
- How far can the probe's activation delays be reduced while keeping source-window focus reliable?

## References

- [Zed terminal OSC 9 notification discussion](https://github.com/zed-industries/zed/discussions/47726)
- [Zed built-in terminal documentation](https://zed.dev/docs/terminal)
- [Zed Terminal Threads notification behavior](https://zed.dev/docs/ai/terminal-threads)
- [tmux manual](https://man.openbsd.org/OpenBSD-current/man1/tmux.1)
- [OpenSSH client configuration](https://man.openbsd.org/ssh_config)
- [OpenSSH server configuration](https://man.openbsd.org/sshd_config)
