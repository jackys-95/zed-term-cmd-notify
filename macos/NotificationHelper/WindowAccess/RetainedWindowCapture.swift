import AppKit
@preconcurrency import ApplicationServices

enum RetainedWindowCaptureError: Error, Equatable {
    case accessibilityPermissionRequired
    case timeoutConfigurationFailed
    case zedNotFrontmost
    case focusedWindowUnavailable
    case invalidWindow
    case focusChangedDuringCapture
}

@MainActor
protocol RetainedWindowEnvironment {
    associatedtype Application: AnyObject
    associatedtype Window

    func accessibilityIsTrusted() -> Bool
    func configureMessagingTimeout(_ timeout: Float) -> Bool
    func frontmostApplication() -> Application?
    func bundleIdentifier(for application: Application) -> String?
    func isTerminated(_ application: Application) -> Bool
    func processIdentifier(for application: Application) -> pid_t
    func focusedWindow(for application: Application) -> Window?
    func ownerProcessIdentifier(of window: Window) -> pid_t?
    func role(of window: Window) -> String?
    func sameWindow(_ lhs: Window, _ rhs: Window) -> Bool
}

@MainActor
final class RetainedSourceWindowReference<Environment: RetainedWindowEnvironment> {
    let application: Environment.Application
    let element: Environment.Window

    private let environment: Environment

    fileprivate init(
        application: Environment.Application,
        element: Environment.Window,
        environment: Environment
    ) {
        self.application = application
        self.element = element
        self.environment = environment
    }

    var processIdentifier: pid_t {
        environment.processIdentifier(for: application)
    }

    func isValid() -> Bool {
        guard environment.accessibilityIsTrusted(),
              !environment.isTerminated(application),
              environment.bundleIdentifier(for: application)
                == RetainedWindowCaptureCoordinator<Environment>.zedBundleIdentifier else {
            return false
        }

        guard environment.ownerProcessIdentifier(of: element) == processIdentifier,
              environment.role(of: element) == "AXWindow" else {
            return false
        }
        return true
    }
}

@MainActor
final class RetainedWindowCaptureCoordinator<Environment: RetainedWindowEnvironment> {
    static var zedBundleIdentifier: String { "dev.zed.Zed" }
    private static var accessibilityTimeout: Float { 0.75 }

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    func capture() throws -> RetainedSourceWindowReference<Environment> {
        guard environment.accessibilityIsTrusted() else {
            throw RetainedWindowCaptureError.accessibilityPermissionRequired
        }
        guard environment.configureMessagingTimeout(Self.accessibilityTimeout) else {
            throw RetainedWindowCaptureError.timeoutConfigurationFailed
        }
        guard let application = environment.frontmostApplication(),
              environment.bundleIdentifier(for: application) == Self.zedBundleIdentifier,
              !environment.isTerminated(application) else {
            throw RetainedWindowCaptureError.zedNotFrontmost
        }

        guard let focusedBefore = environment.focusedWindow(for: application) else {
            throw RetainedWindowCaptureError.focusedWindowUnavailable
        }
        let source = RetainedSourceWindowReference(
            application: application,
            element: focusedBefore,
            environment: environment
        )
        guard source.isValid() else {
            throw RetainedWindowCaptureError.invalidWindow
        }

        guard isStillFrontmost(application) else {
            throw RetainedWindowCaptureError.focusChangedDuringCapture
        }
        guard let focusedAfter = environment.focusedWindow(for: application) else {
            throw RetainedWindowCaptureError.focusedWindowUnavailable
        }
        guard environment.sameWindow(focusedBefore, focusedAfter),
              isStillFrontmost(application) else {
            throw RetainedWindowCaptureError.focusChangedDuringCapture
        }
        return source
    }

    private func isStillFrontmost(_ application: Environment.Application) -> Bool {
        guard let frontmost = environment.frontmostApplication() else {
            return false
        }
        return environment.processIdentifier(for: frontmost)
            == environment.processIdentifier(for: application)
            && !environment.isTerminated(application)
    }
}

extension RetainedWindowCaptureCoordinator where Environment == SystemRetainedWindowEnvironment {
    convenience init() {
        self.init(environment: SystemRetainedWindowEnvironment())
    }
}

@MainActor
struct SystemRetainedWindowEnvironment: RetainedWindowEnvironment {
    func accessibilityIsTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func configureMessagingTimeout(_ timeout: Float) -> Bool {
        AXUIElementSetMessagingTimeout(
            AXUIElementCreateSystemWide(),
            timeout
        ) == .success
    }

    func frontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    func bundleIdentifier(for application: NSRunningApplication) -> String? {
        application.bundleIdentifier
    }

    func isTerminated(_ application: NSRunningApplication) -> Bool {
        application.isTerminated
    }

    func processIdentifier(for application: NSRunningApplication) -> pid_t {
        application.processIdentifier
    }

    func focusedWindow(for application: NSRunningApplication) -> AXUIElement? {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    func ownerProcessIdentifier(of window: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(window, &processIdentifier) == .success else {
            return nil
        }
        return processIdentifier
    }

    func role(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXRoleAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    func sameWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }
}

typealias RetainedWindowCapture =
    RetainedWindowCaptureCoordinator<SystemRetainedWindowEnvironment>
typealias RetainedSourceWindow =
    RetainedSourceWindowReference<SystemRetainedWindowEnvironment>
