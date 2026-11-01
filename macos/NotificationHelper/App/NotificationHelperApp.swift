import AppKit

@NSApplicationMain
@MainActor
final class NotificationHelperApp: NSObject, NSApplicationDelegate {
    private let windowCapture = RetainedWindowCapture()
    private var requestHandler: NotificationRequestHandler<RetainedSourceWindow>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestHandler = NotificationRequestHandler(
            captureSource: { [windowCapture] in
                try? windowCapture.capture()
            },
            deliverCompletion: { _, _, _ in }
        )
    }
}
