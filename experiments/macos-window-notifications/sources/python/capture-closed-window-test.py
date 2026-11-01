#!/usr/bin/env python3
"""Manually trigger the existing probe from the disposable Zed window."""

import json
import os
from pathlib import Path
import time
import uuid

configured_directory = os.environ.get("ZED_WINDOW_PROBE_DIRECTORY")
if not configured_directory or not Path(configured_directory).is_absolute():
    raise SystemExit("Set ZED_WINDOW_PROBE_DIRECTORY to an existing absolute runtime directory.")
DIRECTORY = Path(configured_directory)


def request(action):
    request_id = str(uuid.uuid4())
    temporary = DIRECTORY / ("request-" + request_id + ".new")
    temporary.write_text(json.dumps({"id": request_id, "action": action}))
    os.replace(temporary, DIRECTORY / "request.json")
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            response = json.loads((DIRECTORY / "response.json").read_text())
        except (OSError, ValueError):
            response = {}
        if response.get("requestID") == request_id:
            return response
        time.sleep(0.1)
    raise RuntimeError("No helper response to " + action)


def main():
    status = request("status")
    if not status.get("accessibilityTrusted"):
        raise RuntimeError("The probe does not have Accessibility permission.")
    if status.get("notificationAuthorization") != "raw status 2":
        raise RuntimeError("The probe does not have notification authorization.")

    print("Keep this disposable Zed window foreground while capture runs.", flush=True)
    source = request("capture")
    if source.get("event") != "captured":
        raise RuntimeError(source.get("reason", "Window capture failed."))
    if source.get("retained", {}).get("sourceIsFocused") is not True:
        raise RuntimeError("The captured source is no longer foreground. No notification sent.")
    title = source.get("sourceTitle") or "(untitled)"
    print("Captured window:", title, flush=True)
    print("Confirm this is your disposable window. Ctrl-C cancels.", flush=True)
    input("Press Enter to send the closed-window test notification: ")

    focused = request("check")
    if focused.get("sourceFocused") is not True:
        raise RuntimeError("Source focus changed before confirmation. No notification sent.")
    state = request("retained")
    (DIRECTORY / "closed-window-test-source.json").write_text(
        json.dumps(source, indent=2)
    )
    (DIRECTORY / "closed-window-before-notification.json").write_text(
        json.dumps({"captureToken": source["captureToken"], "retained": state}, indent=2)
    )
    notification = request("notify")
    if notification.get("event") != "notificationRequested" or notification.get("error"):
        raise RuntimeError(str(notification))
    (DIRECTORY / "closed-window-test-notification.json").write_text(
        json.dumps(notification, indent=2)
    )
    print("Notification sent. Wait for the new banner, then close ONLY this window.")
    print("Switch to Firefox, click that notification, and report here.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit("\nTest cancelled.")
    except (OSError, RuntimeError) as error:
        raise SystemExit("Test stopped: " + str(error))
