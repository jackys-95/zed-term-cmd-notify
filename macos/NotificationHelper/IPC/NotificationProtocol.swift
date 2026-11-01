import CoreFoundation
import Foundation

enum NotificationProtocolFailure: Error, Equatable {
    case emptyFrame
    case frameTooLarge
    case incompleteFrame
    case trailingData
    case invalidRequest
    case invalidBinding
    case unsupportedVersion
    case invalidResponse

    var code: String {
        switch self {
        case .emptyFrame:
            "invalid_request"
        case .frameTooLarge:
            "request_too_large"
        case .incompleteFrame, .trailingData, .invalidRequest:
            "invalid_request"
        case .invalidBinding:
            "invalid_binding"
        case .unsupportedVersion:
            "unsupported_version"
        case .invalidResponse:
            "invalid_response"
        }
    }
}

enum NotificationProtocol {
    static let maxFrameBytes = 4 * 1024
    private static let frameHeaderBytes = 4
    private static let maxBindingIDBytes = 128
    private static let version = 1

    enum Request: Equatable, Sendable {
        case bind
        case complete(bindingID: String, elapsedMS: UInt64, exitCode: UInt8)
    }

    enum ErrorCode: String, Equatable, Sendable {
        case invalidRequest = "invalid_request"
        case unsupportedVersion = "unsupported_version"
        case requestTooLarge = "request_too_large"
        case sourceUnavailable = "source_unavailable"
        case unknownBinding = "unknown_binding"
    }

    enum Response: Equatable, Sendable {
        case bound(bindingID: String)
        case accepted
        case error(ErrorCode)
    }

    static func encodeRequest(_ request: Request) throws -> Data {
        let object: [String: Any]
        switch request {
        case .bind:
            object = ["version": version, "type": "bind"]
        case let .complete(bindingID, elapsedMS, exitCode):
            try validateBindingID(bindingID)
            object = [
                "version": version,
                "type": "complete",
                "binding_id": bindingID,
                "elapsed_ms": elapsedMS,
                "exit_code": exitCode,
            ]
        }
        return try encodeObject(object, response: false)
    }

    static func decodeRequest(_ data: Data) throws -> Request {
        let object = try decodeObject(data, response: false)
        guard let type = object["type"] as? String else {
            throw NotificationProtocolFailure.invalidRequest
        }

        switch type {
        case "bind":
            try requireKeys(object, ["version", "type"], response: false)
            try validateVersion(object["version"])
            return .bind
        case "complete":
            try requireKeys(
                object,
                ["version", "type", "binding_id", "elapsed_ms", "exit_code"],
                response: false
            )
            try validateVersion(object["version"])
            guard let bindingID = object["binding_id"] as? String else {
                throw NotificationProtocolFailure.invalidRequest
            }
            try validateBindingID(bindingID)
            let elapsedMS: UInt64 = try integer(object["elapsed_ms"])
            let exitCode: UInt8 = try integer(object["exit_code"])
            return .complete(bindingID: bindingID, elapsedMS: elapsedMS, exitCode: exitCode)
        default:
            throw NotificationProtocolFailure.invalidRequest
        }
    }

    static func encodeResponse(_ response: Response) throws -> Data {
        let object: [String: Any]
        switch response {
        case let .bound(bindingID):
            try validateBindingID(bindingID)
            object = ["version": version, "status": "bound", "binding_id": bindingID]
        case .accepted:
            object = ["version": version, "status": "accepted"]
        case let .error(code):
            object = ["version": version, "status": "error", "error": code.rawValue]
        }
        return try encodeObject(object, response: true)
    }

    static func decodeResponse(_ data: Data) throws -> Response {
        let object = try decodeObject(data, response: true)
        guard let status = object["status"] as? String else {
            throw NotificationProtocolFailure.invalidResponse
        }

        switch status {
        case "bound":
            try requireKeys(object, ["version", "status", "binding_id"], response: true)
            try validateVersion(object["version"], response: true)
            guard let bindingID = object["binding_id"] as? String else {
                throw NotificationProtocolFailure.invalidResponse
            }
            try validateBindingID(bindingID, response: true)
            return .bound(bindingID: bindingID)
        case "accepted":
            try requireKeys(object, ["version", "status"], response: true)
            try validateVersion(object["version"], response: true)
            return .accepted
        case "error":
            try requireKeys(object, ["version", "status", "error"], response: true)
            try validateVersion(object["version"], response: true)
            guard
                let rawCode = object["error"] as? String,
                let code = ErrorCode(rawValue: rawCode)
            else {
                throw NotificationProtocolFailure.invalidResponse
            }
            return .error(code)
        default:
            throw NotificationProtocolFailure.invalidResponse
        }
    }

    static func encodeFrame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else {
            throw NotificationProtocolFailure.emptyFrame
        }
        guard payload.count <= maxFrameBytes else {
            throw NotificationProtocolFailure.frameTooLarge
        }

        let length = UInt32(payload.count)
        var frame = Data(capacity: frameHeaderBytes + payload.count)
        frame.append(UInt8((length >> 24) & 0xff))
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
        frame.append(payload)
        return frame
    }

    static func decodeFrame(_ frame: Data) throws -> Data {
        var decoder = FrameDecoder()
        guard let payload = try decoder.append(frame) else {
            throw NotificationProtocolFailure.incompleteFrame
        }
        try decoder.finish()
        return payload
    }

    private static func encodeObject(
        _ object: [String: Any],
        response: Bool
    ) throws -> Data {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard data.count <= maxFrameBytes else {
                throw NotificationProtocolFailure.frameTooLarge
            }
            return data
        } catch let error as NotificationProtocolFailure {
            throw error
        } catch {
            throw response
                ? NotificationProtocolFailure.invalidResponse
                : NotificationProtocolFailure.invalidRequest
        }
    }

    private static func decodeObject(
        _ data: Data,
        response: Bool
    ) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw response
                ? NotificationProtocolFailure.invalidResponse
                : NotificationProtocolFailure.invalidRequest
        }
        guard data.count <= maxFrameBytes else {
            throw response
                ? NotificationProtocolFailure.invalidResponse
                : NotificationProtocolFailure.frameTooLarge
        }

        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw response
                    ? NotificationProtocolFailure.invalidResponse
                    : NotificationProtocolFailure.invalidRequest
            }
            return object
        } catch let error as NotificationProtocolFailure {
            throw error
        } catch {
            throw response
                ? NotificationProtocolFailure.invalidResponse
                : NotificationProtocolFailure.invalidRequest
        }
    }

    private static func requireKeys(
        _ object: [String: Any],
        _ expected: Set<String>,
        response: Bool
    ) throws {
        guard Set(object.keys) == expected else {
            throw response
                ? NotificationProtocolFailure.invalidResponse
                : NotificationProtocolFailure.invalidRequest
        }
    }

    private static func validateVersion(
        _ value: Any?,
        response: Bool = false
    ) throws {
        do {
            let value: Int = try integer(value)
            guard value == version else {
                throw NotificationProtocolFailure.unsupportedVersion
            }
        } catch let error as NotificationProtocolFailure {
            throw response && error == .invalidRequest ? .invalidResponse : error
        }
    }

    private static func integer<T: FixedWidthInteger>(_ value: Any?) throws -> T {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            throw NotificationProtocolFailure.invalidRequest
        }
        let numberType = String(cString: number.objCType)
        guard numberType != "f", numberType != "d",
              let parsed = T(number.stringValue)
        else {
            throw NotificationProtocolFailure.invalidRequest
        }
        return parsed
    }

    private static func validateBindingID(
        _ bindingID: String,
        response: Bool = false
    ) throws {
        let bytes = Array(bindingID.utf8)
        let isValid = !bytes.isEmpty
            && bytes.count <= maxBindingIDBytes
            && bytes.allSatisfy {
                ($0 >= 48 && $0 <= 57)
                    || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
                    || $0 == 95
                    || $0 == 45
            }
        guard isValid else {
            throw response
                ? NotificationProtocolFailure.invalidResponse
                : NotificationProtocolFailure.invalidBinding
        }
    }
}

struct FrameDecoder {
    private var buffer = Data()
    private var complete = false

    mutating func append(_ chunk: Data) throws -> Data? {
        if complete {
            guard chunk.isEmpty else {
                throw NotificationProtocolFailure.trailingData
            }
            return nil
        }

        let maxBufferBytes = NotificationProtocol.maxFrameBytes + 4
        guard chunk.count <= maxBufferBytes - buffer.count else {
            throw NotificationProtocolFailure.frameTooLarge
        }
        buffer.append(chunk)

        guard buffer.count >= 4 else {
            return nil
        }

        let length = buffer.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length > 0 else {
            throw NotificationProtocolFailure.emptyFrame
        }
        guard length <= NotificationProtocol.maxFrameBytes else {
            throw NotificationProtocolFailure.frameTooLarge
        }

        let frameBytes = 4 + Int(length)
        guard buffer.count <= frameBytes else {
            throw NotificationProtocolFailure.trailingData
        }
        guard buffer.count == frameBytes else {
            return nil
        }

        complete = true
        return buffer.subdata(in: 4..<frameBytes)
    }

    func finish() throws {
        guard complete else {
            throw NotificationProtocolFailure.incompleteFrame
        }
    }
}
