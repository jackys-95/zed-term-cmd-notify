# Lightweight Implementation Plan

**Status:** Draft; production implementation has not started.

Build the first version in small working slices, using the [initial design](initial-design.md) for scope and the [validation matrix](validation-matrix.md) for required behavior and tests. Revise the order and technical choices as implementation produces evidence.

This plan deliberately stays at the level of working outcomes. Implementation and testing will expose constraints that change task boundaries, interfaces, and sequencing; an exhaustive task list now would become stale and add maintenance without improving the next decision. Elaborate the next slice when it is ready to implement, and revise later slices from what we learn. Scope, required behavior, and validation obligations remain explicit in the linked documents.

## Implementation sequence

| Slice | Work | Working result |
| --- | --- | --- |
| 1. Resolve the first uncertainties | Confirm missing-association fallback and terminal diagnostic policy with the user. Probe tmux registration on an isolated server before committing to an attach/create mechanism. Establish the Rust/Swift test setup and a small event/control protocol with bounded requests. | The remaining user-facing policy is explicit, the proposed tmux mechanism has evidence, and automated checks can run without live Zed or AL2023. |
| 2. Mac helper and local client | Adapt the public retained-window probe into the Swift helper. Add the Rust local client, on-demand startup, binding tokens, notification delivery, click handling, and lifetime tied to the associated Zed app. Select a stable app identity and installation location. | A test event produces a silent notification, suppresses it for the exact foreground source, and focuses the retained source on click. Invalid sources are rejected and app-instance termination invalidates bindings. |
| 3. Local Zsh commands | Implement eligibility, exclusions, timing, exit-status handling, lazy shell binding, cache recovery, and manual rebind. Preserve existing hooks and keep subsequent command launches free of client or Accessibility calls once bound. | Local commands in regular integrated terminals notify according to policy; excluded terminals and harnesses continue normally. Failure and recovery paths are covered by isolated shell tests. |
| 4. Plain SSH and remote sender | Add the Rust launcher using existing SSH configuration, one reverse forward, connection registration and teardown, and local terminal cleanup after SSH exits. Build the Linux sender for the actual host and connect remote Zsh hooks to it. | A plain remote command can notify its source window without remote Rust tooling. Sending failures are bounded; disconnect cleanup preserves the SSH result and terminal contents. |
| 5. Persistent tmux | Integrate the validated attach/create registration path and current-route lookup at completion. Cover existing and hidden panes, independent sessions, reconnect during a running command, and connection-wide remote rebind. Add direct tmux entry through the same mechanism if retained as a convenience mode. | Completion after reattachment uses the new connection's window. Completions during a disconnected gap are dropped, and issued notifications retain their original associations. |
| 6. Install and validate the workflow | Provide repeatable build/install instructions for the Mac app, Rust tools, local/remote hooks, and Terminal Thread opt-out. Complete the developer checklist on the actual setup and tune deadlines and focus delays from measurements. | Installation, permissions, local and remote commands, manual recovery, and laptop disconnect behavior are documented and validated to the agreed scope. |

## Iteration and testing

Add the applicable unit tests with each slice and pass them before its end-to-end checks. Use controlled clocks, fake SSH/transport/window operations, and isolated Zsh fixtures. Keep real tmux, macOS focus and permissions, socket deadlines, Linux compatibility, and sleep/disconnect checks in integration testing.

At each slice, record what works, what remains uncertain, and any design change before expanding the implementation. Adjust protocol details, CLI spelling, build target, deadlines, and activation delays when their slice makes them concrete. A failed probe should trigger a bounded revision rather than expansion into a general session manager or Zed fork.

Keep reproducible scripts and outcome summaries shareable. Keep raw device-specific evidence and runtime artifacts outside version control; use synthetic data in tests. Retain the accepted initial capture race as a limitation, with manual rebind as recovery. Manual reconnect and the existing exclusions remain the baseline throughout.
