import AppKit
@preconcurrency import ApplicationServices

// Temporary feasibility experiment: select a uniquely named window using the
// native Dock menu. A renamed window or duplicate title fails instead of guessing.
@MainActor
enum DockWindowPicker {
    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value else {
            throw WindowLookupError.unavailable("Dock \(name) query failed: AXError \(error.rawValue)")
        }
        return value
    }

    private static func children(_ element: AXUIElement) throws -> [AXUIElement] {
        guard let result = try attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            throw WindowLookupError.unavailable("Dock AXChildren returned an unexpected type")
        }
        return result
    }

    private static func role(_ element: AXUIElement) -> String? {
        (try? attribute(element, kAXRoleAttribute)) as? String
    }

    private static func openMenu(pid: pid_t) async throws -> AXUIElement {
        guard AXIsProcessTrusted(),
              let zed = NSRunningApplication(processIdentifier: pid),
              zed.bundleIdentifier == "dev.zed.Zed",
              let zedURL = zed.bundleURL,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw WindowLookupError.unavailable("Accessibility access, source Zed process, or Dock is unavailable")
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        let timeoutError = AXUIElementSetMessagingTimeout(application, 0.5)
        guard timeoutError == .success else {
            throw WindowLookupError.unavailable("Could not bound Dock query time: AXError \(timeoutError.rawValue)")
        }
        let lists = try children(application).filter { role($0) == kAXListRole }
        var matches: [AXUIElement] = []
        for list in lists {
            for item in try children(list) {
                guard let itemURL = (try? attribute(item, kAXURLAttribute)) as? URL,
                      itemURL.standardizedFileURL == zedURL.standardizedFileURL else { continue }
                matches.append(item)
            }
        }
        guard matches.count == 1 else {
            throw WindowLookupError.unavailable("Zed bundle URL matched \(matches.count) Dock items; refusing to guess")
        }
        let icon = matches[0]
        let error = AXUIElementPerformAction(icon, kAXShowMenuAction as CFString)
        guard error == .success else {
            throw WindowLookupError.unavailable("Could not open Zed Dock menu: AXError \(error.rawValue)")
        }
        var lastError = "Menu was not exposed"
        for _ in 0..<8 {
            do {
                let candidates = try children(icon).filter { role($0) == kAXMenuRole }
                if candidates.count == 1 { return candidates[0] }
                lastError = "Dock icon exposed \(candidates.count) menus"
            } catch {
                lastError = String(describing: error)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = AXUIElementPerformAction(icon, kAXCancelAction as CFString)
        throw WindowLookupError.unavailable("Zed Dock menu lookup failed: \(lastError)")
    }

    static func inspect(pid: pid_t) async throws -> [String: Any] {
        let menu = try await openMenu(pid: pid)
        defer { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        let items = try children(menu).map { item -> [String: Any] in
            var names: CFArray?
            let error = AXUIElementCopyActionNames(item, &names)
            return [
                "role": role(item) ?? NSNull(),
                "title": (try? attribute(item, kAXTitleAttribute)) as? String ?? NSNull(),
                "enabled": (try? attribute(item, kAXEnabledAttribute)) as? Bool ?? false,
                "actions": error == .success ? (names as? [String] ?? []) : ["AXError \(error.rawValue)"]
            ]
        }
        return ["menuItems": items]
    }

    static func select(_ source: SourceWindow) async throws -> [String: Any] {
        guard ZedWindows.exists(source) else {
            throw WindowLookupError.unavailable("Source window has closed or is unavailable")
        }
        // These controls in the observed English Dock menu are never window targets.
        guard !["New Window", "Options", "Show All Windows", "Hide", "Quit"].contains(source.title) else {
            throw WindowLookupError.unavailable("Source title conflicts with a Dock control")
        }
        let menu = try await openMenu(pid: source.pid)
        defer { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        let items = try children(menu)
        let matches = try items.filter {
            guard role($0) == kAXMenuItemRole else { return false }
            return (try attribute($0, kAXTitleAttribute) as? String) == source.title
        }
        guard matches.count == 1 else {
            throw WindowLookupError.unavailable("Source title matched \(matches.count) Dock menu items; refusing to guess")
        }
        guard try attribute(matches[0], kAXEnabledAttribute) as? Bool == true,
              ZedWindows.exists(source) else {
            throw WindowLookupError.unavailable("Source menu item is disabled or source window has closed")
        }
        let error = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
        guard error == .success else {
            throw WindowLookupError.unavailable("Could not select source Dock menu item: AXError \(error.rawValue)")
        }
        return ["selectedTitle": source.title, "selectionMethod": "Dock AXShowMenu, then AXPress"]
    }
}
