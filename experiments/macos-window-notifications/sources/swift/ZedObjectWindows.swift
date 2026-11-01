import AppKit
@preconcurrency import ApplicationServices

struct SourceWindow {
    let application: NSRunningApplication
    let title: String
    // Retain the original window object. No numeric ID or saved geometry.
    let element: AXUIElement
    var pid: pid_t { application.processIdentifier }
}

enum WindowLookupError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String {
        switch self { case .unavailable(let message): return message }
    }
}

@MainActor
enum ZedWindows {
    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value else {
            throw WindowLookupError.unavailable("\(name) query failed: AXError \(error.rawValue)")
        }
        return value
    }

    private static func focusedWindow(pid: pid_t) throws -> AXUIElement {
        guard AXIsProcessTrusted() else {
            throw WindowLookupError.unavailable("Accessibility permission is required")
        }
        let value = try attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw WindowLookupError.unavailable("AXFocusedWindow returned an unexpected type")
        }
        return value as! AXUIElement
    }

    private static func validate(_ source: SourceWindow) throws {
        guard AXIsProcessTrusted(), !source.application.isTerminated,
              source.application.bundleIdentifier == "dev.zed.Zed" else {
            throw WindowLookupError.unavailable("Accessibility access or original Zed process is unavailable")
        }
        var pid: pid_t = 0
        let error = AXUIElementGetPid(source.element, &pid)
        guard error == .success, pid == source.pid else {
            throw WindowLookupError.unavailable("Retained window ownership check failed: AXError \(error.rawValue)")
        }
        guard try attribute(source.element, kAXRoleAttribute) as? String == kAXWindowRole else {
            throw WindowLookupError.unavailable("Retained object is not a valid AXWindow")
        }
    }

    static func capture() throws -> SourceWindow {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "dev.zed.Zed" else {
            throw WindowLookupError.unavailable("Source Zed window must be foreground at capture")
        }
        let element = try focusedWindow(pid: app.processIdentifier)
        let title = (try? attribute(element, kAXTitleAttribute)) as? String ?? ""
        let source = SourceWindow(application: app, title: title, element: element)
        try validate(source)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid,
              CFEqual(element, try focusedWindow(pid: source.pid)) else {
            throw WindowLookupError.unavailable("App or window focus changed during capture")
        }
        return source
    }

    static func isFocused(_ source: SourceWindow) throws -> Bool {
        try validate(source)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { return false }
        let first = try focusedWindow(pid: source.pid)
        let second = try focusedWindow(pid: source.pid)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid,
              CFEqual(first, second) else {
            throw WindowLookupError.unavailable("App or window focus changed during the check")
        }
        return CFEqual(source.element, first)
    }

    static func retainedState(_ source: SourceWindow) -> [String: Any] {
        var result: [String: Any] = [
            "identityMethod": "retained public Accessibility object",
            "sourceTitleAtCapture": source.title,
            "sourceProcessRunning": !source.application.isTerminated,
            "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull()
        ]
        do {
            try validate(source)
            result["sourceObjectValid"] = true
        } catch {
            result["sourceObjectValid"] = false
            result["validationError"] = String(describing: error)
        }
        for name in [kAXRoleAttribute, kAXTitleAttribute, kAXMainAttribute,
                     kAXFocusedAttribute, kAXMinimizedAttribute] {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(source.element, name as CFString, &value)
            var field: [String: Any] = ["axError": error.rawValue]
            if let string = value as? String { field["value"] = string }
            else if let number = value as? NSNumber { field["value"] = number }
            result[name] = field
        }
        do {
            result["equalsFocusedAXObject"] = CFEqual(source.element, try focusedWindow(pid: source.pid))
        } catch {
            result["focusedObjectQueryError"] = String(describing: error)
        }
        do { result["sourceIsFocused"] = try isFocused(source) }
        catch { result["focusCheckError"] = String(describing: error) }
        return result
    }

    static func controlRetained(_ source: SourceWindow) -> [String: Any] {
        do { try validate(source) }
        catch { return ["attempted": false, "reason": String(describing: error)] }
        var steps: [[String: Any]] = []
        for (name, value) in [(kAXMinimizedAttribute, false), (kAXMainAttribute, true),
                              (kAXFocusedAttribute, true)] {
            var settable = DarwinBoolean(false)
            let query = AXUIElementIsAttributeSettable(source.element, name as CFString, &settable)
            var step: [String: Any] = ["attribute": name, "settableQueryAXError": query.rawValue,
                                       "settable": settable.boolValue]
            if query == .success, settable.boolValue {
                let error = AXUIElementSetAttributeValue(source.element, name as CFString,
                                                         value ? kCFBooleanTrue : kCFBooleanFalse)
                step["setAXError"] = error.rawValue
                var readback: CFTypeRef?
                let readError = AXUIElementCopyAttributeValue(source.element, name as CFString, &readback)
                step["readbackAXError"] = readError.rawValue
                if let number = readback as? NSNumber { step["readbackValue"] = number }
                steps.append(step)
                if error != .success { return ["attempted": true, "steps": steps, "mayActivate": false] }
            } else {
                steps.append(step)
                if query != .success && query != .attributeUnsupported {
                    return ["attempted": true, "steps": steps, "mayActivate": false]
                }
            }
        }
        let raised = AXUIElementPerformAction(source.element, kAXRaiseAction as CFString)
        steps.append(["action": kAXRaiseAction, "axError": raised.rawValue])
        return ["attempted": true, "steps": steps, "mayActivate": raised == .success]
    }

    static func inspect(pid: pid_t) -> [String: Any] {
        var result: [String: Any] = [
            "pid": pid, "accessibilityTrusted": AXIsProcessTrusted(),
            "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull()
        ]
        do {
            let focused = try focusedWindow(pid: pid)
            result["focusedTitle"] = (try? attribute(focused, kAXTitleAttribute)) as? String ?? ""
            result["focusedRole"] = (try? attribute(focused, kAXRoleAttribute)) as? String ?? ""
        } catch { result["focusedObjectQueryError"] = String(describing: error) }
        return result
    }
}
