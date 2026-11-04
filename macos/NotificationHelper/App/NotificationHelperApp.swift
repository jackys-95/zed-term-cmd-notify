import AppKit

/// Starts the helper's socket server and closes it when the app quits.
@main
@MainActor
final class NotificationHelperApp: NSObject, NSApplicationDelegate {
    private let windowCapture = RetainedWindowCapture()
    private var requestHandler: NotificationRequestHandler<RetainedSourceWindow>?
    private var localSocketServer: LocalSocketServer?

    /// Runs AppKit, the macOS application framework, with this helper as its delegate.
    ///
    /// An application delegate receives events such as app startup and shutdown.
    /// A nib is a compiled file from Xcode's interface editor that stores objects
    /// and their connections. A storyboard describes interface scenes and the
    /// transitions between them.
    ///
    /// This app has neither resource, so the entry point registers the delegate
    /// in code and keeps it alive while AppKit runs.
    static func main() {
        let application = NSApplication.shared
        let delegate = NotificationHelperApp()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    /// Reports whether app startup should resolve and open the default endpoint.
    static func shouldStartSocketServer(environment: [String: String]) -> Bool {
        environment["ZED_NOTIFY_TEST_DISABLE_SOCKET_SERVER"] != "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let handler = NotificationRequestHandler(
            captureSource: { [windowCapture] in
                try? windowCapture.capture()
            },
            deliverCompletion: { _, _, _ in }
        )
        requestHandler = handler

        guard Self.shouldStartSocketServer(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        do {
            let server = try LocalSocketServer(
                endpointPath: LocalSocketServer.defaultEndpointPath()
            ) { request in
                handler.handle(request)
            }
            try server.start()
            localSocketServer = server
        } catch {
            fputs("Notification helper socket startup failed: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let localSocketServer else {
            return .terminateNow
        }
        self.localSocketServer = nil
        localSocketServer.stop {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
