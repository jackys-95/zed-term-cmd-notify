# macOS notification and Zed window experiments

Archived on 2026-11-01 for record keeping. This shareable archive contains probe sources and summaries of the observed outcomes. These are experiments, not the production notification bridge.

`sources/` contains clean copies of the surviving scripts and app metadata. Three scripts now take runtime directories from environment variables instead of paths from the original device. [manifest.json](manifest.json) lists the shareable files. Earlier overwritten revisions cannot be recovered from these sources.

Raw diagnostic evidence and reference snapshots are retained privately and excluded from this repository.

## API approaches and outcomes

| Approach | Source or research | Result and scope |
| --- | --- | --- |
| AppleScript `display notification` through `osascript` | Discussion history; AppleScript app experiment below | A notification appeared, but clicking opened Script Editor. Its Dock behavior did not fit the workflow. The original one-line invocation was not saved as a file. |
| Compiled AppleScript app with `run` and `reopen` handlers | [click-test.applescript](sources/applescript/click-test.applescript) and its [Info.plist](sources/applescript/Info.plist) | Explored app identity and click handling. Posting was recorded, but successful click activation was not established. This was superseded by Swift. |
| App-level activation | AppKit calls in [WindowProbe.swift](sources/swift/WindowProbe.swift) | Early AppKit activation alone did not reliably show Zed across Spaces. An AppleScript app activation retry did switch Spaces, but did not establish exact source-window selection. |
| Public Accessibility plus WindowServer geometry matching | [ZedWindows.swift](sources/swift/ZedWindows.swift) | Earlier identity strategy matched AX position/size with `CGWindowListCopyWindowInfo`. Multiple windows had identical geometry; off-Space AX window enumeration was insufficient. The surviving file combines this path with the later private-ID experiment. |
| Retained AX object with public focus controls | Both window implementations | `AXMain` and `AXRaise`, AppKit activation, then repeated window controls focused the source across Spaces. `AXFocused` was read-only. Earlier versions still performed numeric-ID validation. |
| Private AX-to-WindowServer ID conversion | [PrivateWindowID.swift](sources/swift/PrivateWindowID.swift) and `ZedWindows.swift` | Runtime `_AXUIElementGetWindow` lookup returned the source ID across Spaces; focus still used public APIs. Successful experiment, outside the approved production baseline. |
| Public retained object only | [ZedObjectWindows.swift](sources/swift/ZedObjectWindows.swift) with `WindowProbe.swift` | Approved baseline. No numeric ID, geometry matching, stacking-order matching, or private conversion. Passed cross-Space focus, minimized-window restoration, and closed-window rejection. |
| Dock menu selection by title | [DockWindowPicker.swift](sources/swift/DockWindowPicker.swift) | Prototype only: written but not installed or exercised as the notification click route. Manual Dock selection was observed to work. Duplicate or changed titles make this unsuitable as stable identity. |
| Private focus and Space-switching APIs | Hammerspoon/yabai research | Research only. The probe did not call private focus or Space-switching functions. |
| Public stacking-order matching | Design discussion | Considered but not implemented. The approved object-only baseline does not require it. |

## Source inventory

- `sources/swift/WindowProbe.swift`: the final native notification app driver, its request polling, per-capture token registry, click handling, and diagnostic activation sequence.
- `sources/swift/ZedObjectWindows.swift`: the final public object-only window implementation.
- `sources/swift/ZedWindows.swift` and `PrivateWindowID.swift`: the earlier geometry/private-ID window implementation.
- `sources/swift/DockWindowPicker.swift`: the uninstalled Dock-menu prototype.
- `sources/swift/Info.plist`: the Swift app identity and `LSUIElement` setting for no Dock icon.
- `sources/python/capture-closed-window-test.py`: the manually triggered disposable-window test. It captures from the terminal in the disposable window, asks for confirmation before posting, and leaves window closure to the user.
- `sources/applescript/`: the compiled AppleScript app's script and metadata.

The two window implementations define the same `SourceWindow`, `WindowLookupError`, and `ZedWindows` names. They are alternatives, not files to compile together. The final `WindowProbe.swift` driver matches `ZedObjectWindows.swift`; it cannot be combined unchanged with the earlier `ZedWindows.swift` layout. `DockWindowPicker.swift` refers to that earlier layout and was never wired into the final driver.

## Observed baseline behavior

| Test | Observation |
| --- | --- |
| Cross-Space focus | The original retained object became the focused Zed window; the user confirmed success. |
| Minimized source | The source was valid and minimized before the click; afterward it was unminimized and equal to the focused object. The user confirmed success. No source edits or new Zed diff hook accompanied this test. |
| Closed source | A manually triggered test captured a disposable window. After closure, AX queries returned invalid-element error `-25202`; no activation was requested, the other app remained foreground, and Zed stayed running. An earlier automatically armed attempt was cancelled and is excluded from this result. |

The user confirmation and broader test interpretation are recorded in [the initial design](../../docs/initial-design.md). A successful probe does not establish Zsh hooks, SSH transport, cached shell binding, or end-to-end notification delivery.

## Building or repeating an experiment

`WindowProbe.swift` and `capture-closed-window-test.py` require the same absolute `ZED_WINDOW_PROBE_DIRECTORY` environment variable. The AppleScript experiment requires a separate absolute `ZED_APPLESCRIPT_PROBE_DIRECTORY`. Create fresh temporary runtime directories for each run:

```zsh
export ZED_WINDOW_PROBE_DIRECTORY="$(mktemp -d /private/tmp/window-probe.XXXXXX)"
export ZED_APPLESCRIPT_PROBE_DIRECTORY="$(mktemp -d /private/tmp/applescript-probe.XXXXXX)"
```

Run the Swift app-bundle executable and Python harness from shells with the same environment. Finder and Launch Services launches may not inherit these variables. The AppleScript experiment is historical and remains outside the production direction.

The final Swift source can be compiled from the repository root:

```zsh
probe_build=$(mktemp -d /private/tmp/zed-probe-build.XXXXXX)
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -module-cache-path "$probe_build/module-cache" \
  experiments/macos-window-notifications/sources/swift/WindowProbe.swift \
  experiments/macos-window-notifications/sources/swift/ZedObjectWindows.swift \
  -o "$probe_build/WindowProbe" \
  -framework AppKit -framework ApplicationServices \
  -framework UserNotifications
```

Compilation alone does not install or launch an app. Native notifications were tested in an app bundle with the saved Swift `Info.plist`, executable at `Contents/MacOS/WindowProbe`, and an ad-hoc signature. Notification authorization and Accessibility authorization are separate. The installed experimental app was `~/Applications/Zed Window Probe.app`; rebuilding or replacing it can require updating its Accessibility permission entry.

The IPC driver polls `request.json` every 0.25 seconds and accepts a UUID request ID with an action such as `status`, `capture`, `check`, `retained`, `inspect`, `notify`, `notification-permission`, `permissions`, or `quit`. Responses carry the matching request ID; notification clicks also save `last-click.json`. The Python closed-window script demonstrates the request protocol. This single-mailbox protocol is diagnostic code, not a concurrent production transport.

The driver retains diagnostic waits of 100 ms, one second, and 750 ms during click activation. These delays were useful for the experiment; production latency remains to be designed. The initial design specifies helper lifetime through Zed app exit, but this archived driver does not implement that lifecycle.

Third-party source snapshots, compiled binaries, application bundles, Swift module caches, and runtime files are excluded. The app metadata needed to understand the experiments is preserved separately.

## Archive verification

After parameterizing the runtime directories, manifests and plist files parsed, the Python script passed syntax validation, the final object-only app compiled with Swift 6 and warnings treated as errors, and the AppleScript script compiled. The earlier identity implementation, private adapter, and uninstalled Dock prototype passed a separate type check before restructuring; their contents are unchanged. No archived app was launched or installed during these checks. Compilation alone does not validate notification delivery or native focus.
