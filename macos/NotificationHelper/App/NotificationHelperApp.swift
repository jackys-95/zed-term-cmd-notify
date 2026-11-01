import AppKit

@NSApplicationMain
@MainActor
final class NotificationHelperApp: NSObject, NSApplicationDelegate {
    private let windowCapture = RetainedWindowCapture()
    private var requestHandler: NotificationRequestHandler<RetainedSourceWindow>?
    private var localSocketServer: LocalSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let handler = NotificationRequestHandler(
            captureSource: { [windowCapture] in
                try? windowCapture.capture()
            },
            deliverCompletion: { _, _, _ in }
        )
        requestHandler = handler

        guard ProcessInfo.processInfo.environment["ZED_NOTIFY_TEST_DISABLE_SOCKET_SERVER"] != "1" else {
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
