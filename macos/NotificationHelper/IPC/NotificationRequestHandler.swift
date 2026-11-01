import Foundation

@MainActor
final class NotificationRequestHandler<Source: AnyObject> {
    typealias SourceCapture = @MainActor () -> Source?
    typealias CompletionDelivery = @MainActor (Source, UInt64, UInt8) -> Void
    typealias BindingIDGenerator = () -> String

    private let captureSource: SourceCapture
    private let deliverCompletion: CompletionDelivery
    private let makeBindingID: BindingIDGenerator
    private let bindings = BindingRegistry<Source>()

    init(
        captureSource: @escaping SourceCapture,
        deliverCompletion: @escaping CompletionDelivery,
        makeBindingID: @escaping BindingIDGenerator = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.captureSource = captureSource
        self.deliverCompletion = deliverCompletion
        self.makeBindingID = makeBindingID
    }

    func handle(_ request: NotificationProtocol.Request) -> NotificationProtocol.Response {
        switch request {
        case .bind:
            guard let source = captureSource() else {
                return .error(.sourceUnavailable)
            }
            return .bound(bindingID: insert(source))

        case let .complete(bindingID, elapsedMS, exitCode):
            guard let source = bindings.source(for: bindingID) else {
                return .error(.unknownBinding)
            }
            deliverCompletion(source, elapsedMS, exitCode)
            return .accepted
        }
    }

    private func insert(_ source: Source) -> String {
        while true {
            let bindingID = makeBindingID()
            if bindings.insert(source, for: bindingID) {
                return bindingID
            }
        }
    }
}
