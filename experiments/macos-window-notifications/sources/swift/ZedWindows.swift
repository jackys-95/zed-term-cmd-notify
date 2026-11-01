import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

struct SourceWindow {
    let pid: pid_t
    let windowID: CGWindowID
    let accessibilityIdentifier: String?
    let title: String
    let identityMethod: String
    let identityDiagnostics: [String: Any]
    // Swift retains this CF object for the lifetime of the capture.
    let element: AXUIElement
}

enum WindowLookupError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String {
        switch self { case .unavailable(let message): return message }
    }
}

// Retain the original AX object. Compare private ID conversion with geometry;
// keep geometry as the fallback when the private symbol is unavailable.
@MainActor
enum ZedWindows {
    private struct Row {
        let id: CGWindowID
        let frame: CGRect
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else {
            throw WindowLookupError.unavailable("\(name) query failed: AXError \(error.rawValue)")
        }
        guard let value else {
            throw WindowLookupError.unavailable("\(name) query succeeded without a value")
        }
        return value
    }

    private static func rectangle(_ element: AXUIElement) throws -> CGRect {
        let rawPoint = try attribute(element, kAXPositionAttribute)
        let rawSize = try attribute(element, kAXSizeAttribute)
        guard CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else {
            throw WindowLookupError.unavailable("Window geometry has unexpected Accessibility types")
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else {
            throw WindowLookupError.unavailable("Window geometry could not be decoded")
        }
        return CGRect(origin: point, size: size)
    }

    private static func matchingFrames(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 &&
        abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private static func rows(pid: pid_t, onScreenOnly: Bool = false) -> [Row] {
        let options: CGWindowListOption = onScreenOnly ? .optionOnScreenOnly : .optionAll
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = item[kCGWindowNumber as String] as? NSNumber,
                  let bounds = item[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"] else { return nil }
            return Row(id: number.uint32Value,
                       frame: CGRect(x: x.doubleValue, y: y.doubleValue,
                                     width: width.doubleValue, height: height.doubleValue))
        }
    }

    private static func windows(pid: pid_t) throws -> [AXUIElement] {
        guard let result = try attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] else {
            throw WindowLookupError.unavailable("AXWindows query returned an unexpected type")
        }
        return result
    }

    private static func focusedWindow(pid: pid_t) throws -> AXUIElement {
        guard AXIsProcessTrusted() else {
            throw WindowLookupError.unavailable("Accessibility permission is required")
        }
        let value = try attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw WindowLookupError.unavailable("AXFocusedWindow query returned an unexpected type")
        }
        return value as! AXUIElement
    }

    private static func identity(pid: pid_t, element: AXUIElement) throws -> SourceWindow {
        var diagnostics: [String: Any] = [
            "privateConversion": ["available": PrivateWindowID.available]
        ]
        var geometryIDs: [CGWindowID] = []
        do {
            let frame = try rectangle(element)
            geometryIDs = rows(pid: pid, onScreenOnly: true)
                .filter { matchingFrames($0.frame, frame) }.map(\.id)
            diagnostics["geometryMatchingIDs"] = geometryIDs
        } catch {
            diagnostics["geometryError"] = String(describing: error)
        }
        let id: CGWindowID
        let method: String
        if PrivateWindowID.available {
            id = try PrivateWindowID.lookup(element)
            diagnostics["privateConversion"] = ["available": true, "windowID": id]
            guard rows(pid: pid).contains(where: { $0.id == id }) else {
                throw WindowLookupError.unavailable("Converted window ID is not a window of the original Zed process")
            }
            diagnostics["geometryAgrees"] = geometryIDs.count == 1 && geometryIDs[0] == id
            if geometryIDs.count == 1, geometryIDs[0] != id {
                throw WindowLookupError.unavailable("Private conversion and unique geometry match disagree")
            }
            method = "_AXUIElementGetWindow"
        } else {
            guard geometryIDs.count == 1 else {
                throw WindowLookupError.unavailable("Focused window matched \(geometryIDs.count) window IDs; refusing to guess")
            }
            id = geometryIDs[0]
            method = "public geometry fallback"
        }
        let identifier = (try? attribute(element, kAXIdentifierAttribute)) as? String
        let title = (try? attribute(element, kAXTitleAttribute)) as? String ?? ""
        return SourceWindow(pid: pid, windowID: id,
                            accessibilityIdentifier: identifier.flatMap { $0.isEmpty ? nil : $0 },
                            title: title, identityMethod: method, identityDiagnostics: diagnostics,
                            element: element)
    }

    static func capture() throws -> SourceWindow {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "dev.zed.Zed" else {
            throw WindowLookupError.unavailable("The source Zed window must be foreground at capture")
        }
        let result = try identity(pid: app.processIdentifier, element: focusedWindow(pid: app.processIdentifier))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == result.pid else {
            throw WindowLookupError.unavailable("App focus changed during capture")
        }
        return result
    }

    static func isFocused(_ source: SourceWindow) throws -> Bool {
        guard rows(pid: source.pid).contains(where: { $0.id == source.windowID }) else {
            throw WindowLookupError.unavailable("The source window has closed or is unavailable")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else { return false }
        let focused = try identity(pid: source.pid, element: focusedWindow(pid: source.pid))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid else {
            throw WindowLookupError.unavailable("App focus changed during the check")
        }
        return focused.windowID == source.windowID
    }

    static func isOnScreen(_ source: SourceWindow) -> Bool {
        rows(pid: source.pid, onScreenOnly: true).contains { $0.id == source.windowID }
    }

    static func exists(_ source: SourceWindow) -> Bool {
        rows(pid: source.pid).contains { $0.id == source.windowID }
    }

    static func retainedState(_ source: SourceWindow) -> [String: Any] {
        var result: [String: Any] = [
            "sourceWindowID": source.windowID,
            "identityMethod": source.identityMethod,
            "identityAtCapture": source.identityDiagnostics,
            "privateConversionNow": PrivateWindowID.inspect(source.element),
            "sourceWindowExists": exists(source),
            "sourceOnScreen": isOnScreen(source),
            "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull()
        ]
        for name in [kAXRoleAttribute, kAXTitleAttribute, kAXMainAttribute, kAXFocusedAttribute] {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(source.element, name as CFString, &value)
            var field: [String: Any] = ["axError": error.rawValue]
            if let value {
                if let string = value as? String { field["value"] = string }
                else if let number = value as? NSNumber { field["value"] = number }
            }
            result[name] = field
        }
        do {
            let frame = try rectangle(source.element)
            result["frame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        } catch {
            result["geometryError"] = String(describing: error)
        }
        do {
            let focused = try focusedWindow(pid: source.pid)
            result["equalsFocusedAXObject"] = CFEqual(source.element, focused)
        } catch {
            result["focusedObjectQueryError"] = String(describing: error)
        }
        return result
    }

    static func controlRetained(_ source: SourceWindow) -> [String: Any] {
        var steps: [[String: Any]] = []
        guard AXIsProcessTrusted(), exists(source) else {
            return ["attempted": false, "reason": "Accessibility access or source window is unavailable"]
        }
        do {
            guard try attribute(source.element, kAXRoleAttribute) as? String == kAXWindowRole else {
                return ["attempted": false, "reason": "Retained object is not an AXWindow"]
            }
            if source.identityMethod == "_AXUIElementGetWindow",
               try PrivateWindowID.lookup(source.element) != source.windowID {
                return ["attempted": false, "reason": "Retained object's window ID changed; refusing to focus"]
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == source.pid,
               !isOnScreen(source),
               CFEqual(source.element, try focusedWindow(pid: source.pid)) {
                return ["attempted": false, "reason": "Retained object also represents the focused off-source window; refusing to guess"]
            }
        } catch {
            return ["attempted": false, "reason": String(describing: error)]
        }
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
                if error != .success {
                    return ["attempted": true, "steps": steps, "mayActivate": false]
                }
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
        func describe(_ window: AXUIElement) -> [String: Any] {
            var detail: [String: Any] = [:]
            for name in [kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute] {
                do {
                    detail[name] = try attribute(window, name) as? String ?? "<unexpected type>"
                } catch {
                    detail[name] = ["error": String(describing: error)]
                }
            }
            do {
                let frame = try rectangle(window)
                detail["frame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            } catch {
                detail["frame"] = ["error": String(describing: error)]
            }
            return detail
        }
        var result: [String: Any] = [
            "pid": pid,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? NSNull(),
            "windowIDs": rows(pid: pid).map { ["id": $0.id, "x": $0.frame.minX, "y": $0.frame.minY,
                                             "width": $0.frame.width, "height": $0.frame.height] },
            "onScreenWindowIDs": rows(pid: pid, onScreenOnly: true).map(\.id)
        ]
        do {
            result["accessibilityWindows"] = try windows(pid: pid).map(describe)
        } catch {
            result["accessibilityWindowsError"] = String(describing: error)
        }
        do {
            result["focusedAccessibilityWindow"] = describe(try focusedWindow(pid: pid))
        } catch {
            result["focusedAccessibilityWindowError"] = String(describing: error)
        }
        return result
    }
}
