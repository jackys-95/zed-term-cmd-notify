import Foundation

enum ProtocolInteropError: Error {
    case usage
    case unexpectedRequest
}

@main
struct ProtocolInterop {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ProtocolInteropError.usage
        }

        let directory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        let bindPayload = try NotificationProtocol.decodeFrame(
            Data(contentsOf: directory.appendingPathComponent("bind-request.frame"))
        )
        guard try NotificationProtocol.decodeRequest(bindPayload) == .bind else {
            throw ProtocolInteropError.unexpectedRequest
        }

        let completePayload = try NotificationProtocol.decodeFrame(
            Data(contentsOf: directory.appendingPathComponent("complete-request.frame"))
        )
        guard
            try NotificationProtocol.decodeRequest(completePayload)
                == .complete(
                    bindingID: "interop_binding_01",
                    elapsedMS: 31_000,
                    exitCode: 0
                )
        else {
            throw ProtocolInteropError.unexpectedRequest
        }

        let responses: [(String, NotificationProtocol.Response)] = [
            ("bound-response.frame", .bound(bindingID: "interop_binding_01")),
            ("accepted-response.frame", .accepted),
        ]
        for (filename, response) in responses {
            let payload = try NotificationProtocol.encodeResponse(response)
            let frame = try NotificationProtocol.encodeFrame(payload)
            try frame.write(
                to: directory.appendingPathComponent(filename),
                options: .atomic
            )
        }
    }
}
