import AppKit
@preconcurrency import ApplicationServices
import Foundation
@preconcurrency import UserNotifications

// A feasibility probe, not the production SSH receiver.
// Retain the source AX window object and test only documented control APIs.
@MainActor
final class WindowProbe: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let directory: URL
    private var lastRequestID: String?
    private var timer: Timer?
    private var sourceWindow: SourceWindow?
    private var sourceToken: String?
    private var captures: [String: SourceWindow] = [:]
    private var notificationAuthorization = "not checked"

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        refreshNotificationAuthorization()
        let timeout = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.75)
        report(["event": "started", "accessibilityTrusted": AXIsProcessTrusted(),
                "processAXTimeoutError": timeout.rawValue])
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readRequest() }
        }
    }

    private func report(_ fields: [String: Any], requestID: String? = nil) {
        var result = fields
        result["timestamp"] = ISO8601DateFormatter().string(from: Date())
        if let requestID { result["requestID"] = requestID }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        do {
            try data.write(to: directory.appendingPathComponent("response.json"), options: .atomic)
            if fields["event"] as? String == "notificationClicked" {
                try data.write(to: directory.appendingPathComponent("last-click.json"), options: .atomic)
            }
        } catch {
            NSLog("Window probe could not write response: %@", String(describing: error))
        }
    }

    private func readRequest() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("request.json")),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = request["id"], UUID(uuidString: id) != nil,
              id != lastRequestID,
              let action = request["action"] else { return }
        lastRequestID = id
        switch action {
        case "permissions":
            let trusted = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            )
            report(["event": "accessibilityPermissionRequested", "accessibilityTrusted": trusted], requestID: id)
        case "notification-permission":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
                let errorMessage = error.map { String(describing: $0) }
                Task { @MainActor in
                    self.refreshNotificationAuthorization()
                    self.report([
                        "event": "notificationPermissionRequested",
                        "granted": granted,
                        "error": errorMessage ?? NSNull()
                    ], requestID: id)
                }
            }
        case "capture":
            captureSource(requestID: id)
        case "check":
            checkSource(requestID: id)
        case "inspect":
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "dev.zed.Zed" }) {
                report(["event": "inspected", "windows": ZedWindows.inspect(pid: app.processIdentifier)], requestID: id)
            } else {
                report(["event": "inspectionFailed", "reason": "Zed is not running"], requestID: id)
            }
        case "retained":
            if let sourceWindow {
                report(["event": "retainedChecked", "retained": ZedWindows.retainedState(sourceWindow)], requestID: id)
            } else {
                report(["event": "retainedRejected", "reason": "No captured source"], requestID: id)
            }
        case "notify":
            postNotification(requestID: id)
        case "status":
            report([
                "event": "status",
                "accessibilityTrusted": AXIsProcessTrusted(),
                "notificationAuthorization": notificationAuthorization,
                "hasCapturedWindow": sourceWindow != nil,
                "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull()
            ], requestID: id)
        case "quit":
            report(["event": "stopped"], requestID: id)
            NSApplication.shared.terminate(nil)
        default:
            report(["event": "error", "reason": "unknown action"], requestID: id)
        }
    }

    private func captureSource(requestID: String) {
        do {
            let source = try ZedWindows.capture()
            sourceWindow = source
            let token = UUID().uuidString
            sourceToken = token
            captures[token] = source
            report(["event": "captured", "sourcePID": source.pid,
                    "sourceTitle": source.title,
                    "captureToken": token,
                    "retained": ZedWindows.retainedState(source)], requestID: requestID)
        } catch {
            sourceWindow = nil
            sourceToken = nil
            report(["event": "captureRejected", "reason": String(describing: error)], requestID: requestID)
        }
    }

    private func checkSource(requestID: String) {
        guard let sourceWindow else {
            report(["event": "checked", "sourceFocused": NSNull(), "fallbackRequired": true,
                    "reason": "permission or captured window missing"], requestID: requestID)
            return
        }
        do {
            let focused = try ZedWindows.isFocused(sourceWindow)
            report(["event": "checked", "sourceFocused": focused, "fallbackRequired": false,
                    "identityMethod": "retained public Accessibility object"],
                   requestID: requestID)
        } catch {
            report(["event": "checked", "sourceFocused": NSNull(), "fallbackRequired": true,
                    "reason": String(describing: error)],
                   requestID: requestID)
        }
    }

    private func refreshNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus.rawValue
            Task { @MainActor in self.notificationAuthorization = "raw status \(status)" }
        }
    }

    private func postNotification(requestID: String) {
        guard let sourceWindow, let sourceToken else {
            report(["event": "notificationRejected", "reason": "Capture the source window first"], requestID: requestID)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Zed object-only window test"
        content.body = "Click to focus the originally captured Zed window."
        content.sound = nil
        content.userInfo = ["sourcePID": sourceWindow.pid, "captureToken": sourceToken]
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            let errorMessage = error.map { String(describing: $0) }
            Task { @MainActor in
                self.report(["event": "notificationRequested", "error": errorMessage ?? NSNull()],
                            requestID: requestID)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let token = info["captureToken"] as? String
        Task { @MainActor in
            guard action == UNNotificationDefaultActionIdentifier else {
                self.report(["event": "notificationOtherAction", "action": action])
                return
            }
            guard let token, let source = self.captures[token] else {
                self.report(["event": "notificationClicked", "activationRequested": false,
                             "reason": "Notification's original retained capture is unavailable"])
                return
            }
            let before = NSWorkspace.shared.frontmostApplication
            let beforeRetained = ZedWindows.retainedState(source)
            let beforeControl = ZedWindows.controlRetained(source)
            var activation: [String: Any] = ["requested": false]
            var afterControl: [String: Any] = ["attempted": false]
            var afterActivation: [String: Any] = [:]
            do {
                guard beforeControl["mayActivate"] as? Bool == true else {
                    throw WindowLookupError.unavailable("Retained source could not be controlled; see AX operation results")
                }
                let target = source.application
                guard !target.isTerminated, target.bundleIdentifier == "dev.zed.Zed" else {
                    throw WindowLookupError.unavailable("Original Zed process is unavailable")
                }
                if #available(macOS 14.0, *) {
                    NSApplication.shared.activate()
                    try await Task.sleep(for: .milliseconds(100))
                    NSApplication.shared.yieldActivation(to: target)
                    activation = [
                        "requested": true,
                        "method": "NSApp.activate, yieldActivation, activate(from:options:)",
                        "helperIsActive": NSRunningApplication.current.isActive,
                        "requestAllowed": target.activate(from: NSRunningApplication.current, options: [])
                    ]
                } else {
                    activation = ["requested": true, "method": "activate(options:)",
                                  "requestSent": target.activate(options: [])]
                }
                try await Task.sleep(for: .seconds(1))
                afterActivation = ZedWindows.retainedState(source)
                afterControl = ZedWindows.controlRetained(source)
                try await Task.sleep(for: .milliseconds(750))
                let after = NSWorkspace.shared.frontmostApplication
                let focusResult: [String: Any]
                do {
                    focusResult = ["focused": try ZedWindows.isFocused(source)]
                } catch {
                    focusResult = ["error": String(describing: error)]
                }
                self.report([
                    "event": "notificationClicked",
                    "captureToken": token,
                    "controlBeforeActivation": beforeControl,
                    "controlAfterActivation": afterControl,
                    "activation": activation,
                    "sourceTitle": source.title,
                    "frontmostBefore": before?.bundleIdentifier ?? NSNull(),
                    "frontmostAfter": after?.bundleIdentifier ?? NSNull(),
                    "zedIsForeground": after?.bundleIdentifier == "dev.zed.Zed",
                    "sourceWindowFocusCheck": focusResult,
                    "retainedBefore": beforeRetained,
                    "retainedAfterActivation": afterActivation,
                    "retainedAfter": ZedWindows.retainedState(source)
                ])
            } catch {
                self.report(["event": "notificationClicked", "activationError": String(describing: error),
                             "sourceTitle": source.title,
                             "captureToken": token,
                             "controlBeforeActivation": beforeControl,
                             "controlAfterActivation": afterControl,
                             "activation": activation,
                             "frontmostBefore": before?.bundleIdentifier ?? NSNull(),
                             "frontmostAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
                             "retainedBefore": beforeRetained,
                             "retainedAfterActivation": afterActivation,
                             "retainedAfter": ZedWindows.retainedState(source)])
            }
        }
        completionHandler()
    }
}

@main
struct ProbeMain {
    @MainActor
    static func main() {
        guard let path = ProcessInfo.processInfo.environment["ZED_WINDOW_PROBE_DIRECTORY"],
              path.hasPrefix("/") else {
            NSLog("Set ZED_WINDOW_PROBE_DIRECTORY to an existing absolute runtime directory.")
            return
        }
        let application = NSApplication.shared
        let delegate = WindowProbe(directory: URL(fileURLWithPath: path))
        application.delegate = delegate
        application.run()
    }
}
