import XCTest
import Foundation
@testable import NotificationHelper

final class NotificationHelperTests: XCTestCase {
    func testSharedValidRequestFixturesDecodeAndRoundTrip() throws {
        for fixture in try fixtures(named: "valid_requests") {
            let payload = try jsonData(fixture["payload"])
            let request = try NotificationProtocol.decodeRequest(payload)
            let encoded = try NotificationProtocol.encodeRequest(request)
            try assertJSONEqual(encoded, fixture["payload"], named: fixture["name"])
        }
    }

    func testSharedValidResponseFixturesDecodeAndRoundTrip() throws {
        for fixture in try fixtures(named: "valid_responses") {
            let payload = try jsonData(fixture["payload"])
            let response = try NotificationProtocol.decodeResponse(payload)
            let encoded = try NotificationProtocol.encodeResponse(response)
            try assertJSONEqual(encoded, fixture["payload"], named: fixture["name"])
        }
    }

    func testSharedInvalidRequestFixturesAreRejected() throws {
        for fixture in try fixtures(named: "invalid_requests") {
            let payload = try jsonData(fixture["payload"])
            XCTAssertThrowsError(
                try NotificationProtocol.decodeRequest(payload),
                fixture["name"] as? String ?? "invalid request fixture"
            ) { error in
                XCTAssertEqual(
                    (error as? NotificationProtocolFailure)?.code,
                    fixture["error"] as? String
                )
            }
        }
    }

    func testSharedInvalidResponseFixturesAreRejected() throws {
        for fixture in try fixtures(named: "invalid_responses") {
            let payload = try jsonData(fixture["payload"])
            XCTAssertThrowsError(
                try NotificationProtocol.decodeResponse(payload),
                fixture["name"] as? String ?? "invalid response fixture"
            ) { error in
                XCTAssertEqual(
                    (error as? NotificationProtocolFailure)?.code,
                    fixture["error"] as? String
                )
            }
        }
    }

    func testSharedMalformedJSONFixturesAreRejected() throws {
        for fixture in try fixtures(named: "invalid_json") {
            let payload = try XCTUnwrap(fixture["payload"] as? String)
            XCTAssertThrowsError(
                try NotificationProtocol.decodeRequest(Data(payload.utf8)),
                fixture["name"] as? String ?? "malformed JSON fixture"
            ) { error in
                XCTAssertEqual(
                    error as? NotificationProtocolFailure,
                    .invalidRequest
                )
            }
        }
    }

    func testSharedBindingIDBoundariesAreEnforced() throws {
        let root = try fixtureRoot()
        let boundaries = try XCTUnwrap(root["boundaries"] as? [String: Any])
        let maxBindingIDBytes = try XCTUnwrap(boundaries["max_binding_id_bytes"] as? Int)
        let character = try XCTUnwrap(boundaries["binding_id_character"] as? String)
        XCTAssertEqual(character.utf8.count, 1)

        let validBindingID = String(repeating: character, count: maxBindingIDBytes)
        let validRequest = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "type": "complete",
            "binding_id": validBindingID,
            "elapsed_ms": 1,
            "exit_code": 0,
        ])
        XCTAssertNoThrow(try NotificationProtocol.decodeRequest(validRequest))

        let invalidBindingID = String(repeating: character, count: maxBindingIDBytes + 1)
        let invalidRequest = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "type": "complete",
            "binding_id": invalidBindingID,
            "elapsed_ms": 1,
            "exit_code": 0,
        ])
        XCTAssertThrowsError(try NotificationProtocol.decodeRequest(invalidRequest)) { error in
            XCTAssertEqual(error as? NotificationProtocolFailure, .invalidBinding)
        }

        let validResponse = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "status": "bound",
            "binding_id": validBindingID,
        ])
        XCTAssertNoThrow(try NotificationProtocol.decodeResponse(validResponse))

        let invalidResponse = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "status": "bound",
            "binding_id": invalidBindingID,
        ])
        XCTAssertThrowsError(try NotificationProtocol.decodeResponse(invalidResponse)) { error in
            XCTAssertEqual(error as? NotificationProtocolFailure, .invalidResponse)
        }
    }

    func testFrameDecoderHandlesPartialInput() throws {
        let payload = try NotificationProtocol.encodeRequest(.bind)
        let frame = try NotificationProtocol.encodeFrame(payload)
        var decoder = FrameDecoder()
        var decoded: Data?

        for start in stride(from: 0, to: frame.count, by: 2) {
            let end = min(start + 2, frame.count)
            if let completePayload = try decoder.append(frame.subdata(in: start..<end)) {
                decoded = completePayload
            }
        }

        XCTAssertEqual(decoded, payload)
        XCTAssertNoThrow(try decoder.finish())
    }

    func testFrameDecoderRejectsEmptyOversizedIncompleteAndTrailingData() throws {
        let boundaries = try XCTUnwrap(
            try fixtureRoot()["boundaries"] as? [String: Any]
        )
        let maxFrameBytes = try XCTUnwrap(boundaries["max_frame_bytes"] as? Int)
        XCTAssertEqual(maxFrameBytes, NotificationProtocol.maxFrameBytes)

        XCTAssertThrowsError(try NotificationProtocol.encodeFrame(Data())) { error in
            XCTAssertEqual(error as? NotificationProtocolFailure, .emptyFrame)
        }

        let maxPayload = Data(repeating: 0x78, count: maxFrameBytes)
        let maxFrame = try NotificationProtocol.encodeFrame(maxPayload)
        XCTAssertEqual(maxFrame.count, maxFrameBytes + 4)
        XCTAssertEqual(try NotificationProtocol.decodeFrame(maxFrame), maxPayload)

        let oversizedFrameBytes = maxFrameBytes + 1
        let oversizedPayload = Data(repeating: 0x78, count: oversizedFrameBytes)
        XCTAssertThrowsError(try NotificationProtocol.encodeFrame(oversizedPayload)) { error in
            XCTAssertEqual(error as? NotificationProtocolFailure, .frameTooLarge)
        }

        let oversizedLength = UInt32(oversizedFrameBytes)
        var oversizedHeader = Data()
        oversizedHeader.append(UInt8((oversizedLength >> 24) & 0xff))
        oversizedHeader.append(UInt8((oversizedLength >> 16) & 0xff))
        oversizedHeader.append(UInt8((oversizedLength >> 8) & 0xff))
        oversizedHeader.append(UInt8(oversizedLength & 0xff))
        XCTAssertEqual(oversizedHeader, Data([0, 0, 16, 1]))
        var oversizedDecoder = FrameDecoder()
        XCTAssertThrowsError(try oversizedDecoder.append(oversizedHeader)) { error in
            XCTAssertEqual(error as? NotificationProtocolFailure, .frameTooLarge)
        }

        let frame = try NotificationProtocol.encodeFrame(Data("{}".utf8))
        var incompleteDecoder = FrameDecoder()
        XCTAssertNil(try incompleteDecoder.append(Data(frame.dropLast())))
        XCTAssertThrowsError(try incompleteDecoder.finish()) { error in
            XCTAssertEqual(error as? NotificationProtocolFailure, .incompleteFrame)
        }

        var trailingFrame = frame
        trailingFrame.append(0x78)
        XCTAssertThrowsError(try NotificationProtocol.decodeFrame(trailingFrame)) { error in
            XCTAssertEqual(error as? NotificationProtocolFailure, .trailingData)
        }
    }

    private func fixtures(named key: String) throws -> [[String: Any]] {
        let root = try fixtureRoot()
        return try XCTUnwrap(root[key] as? [[String: Any]])
    }

    private func fixtureRoot() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "messages", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func jsonData(_ value: Any?) throws -> Data {
        let value = try XCTUnwrap(value)
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func assertJSONEqual(
        _ actual: Data,
        _ expectedObject: Any?,
        named name: Any?
    ) throws {
        let actualObject = try JSONSerialization.jsonObject(with: actual)
        let expectedObject = try XCTUnwrap(expectedObject)
        XCTAssertEqual(
            NSDictionary(dictionary: actualObject as? [String: Any] ?? [:]),
            NSDictionary(dictionary: expectedObject as? [String: Any] ?? [:]),
            name as? String ?? "JSON payload"
        )
    }
}
