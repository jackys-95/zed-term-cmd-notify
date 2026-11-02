import Foundation
import XCTest
@testable import NotificationHelper

final class NotificationHelperTests: XCTestCase {
    @MainActor
    func testTestHostReceivesDisableServerFlagAndSkipsDefaultEndpointStartup() {
        let environment = ProcessInfo.processInfo.environment
        XCTAssertEqual(
            environment["ZED_NOTIFY_TEST_DISABLE_SOCKET_SERVER"],
            "1"
        )
        XCTAssertFalse(NotificationHelperApp.shouldStartSocketServer(environment: environment))
    }

    @MainActor
    func testRetainedWindowCaptureKeepsTheStableFocusedZedWindow() throws {
        let environment = FakeRetainedWindowEnvironment()
        let capture = RetainedWindowCaptureCoordinator(environment: environment)

        let source = try capture.capture()

        XCTAssertTrue(source.application === environment.zedApplication)
        XCTAssertTrue(source.element === environment.focusedWindow)
        XCTAssertEqual(source.processIdentifier, environment.zedApplication.processIdentifier)
        XCTAssertTrue(source.isValid())
        XCTAssertEqual(environment.lastConfiguredTimeout, 0.75)
    }

    @MainActor
    func testRetainedWindowCaptureRequiresAccessibilityAndConfiguresTimeout() {
        let untrustedEnvironment = FakeRetainedWindowEnvironment()
        untrustedEnvironment.accessibilityTrusted = false
        assertCaptureError(
            .accessibilityPermissionRequired,
            in: untrustedEnvironment
        )

        let timeoutFailureEnvironment = FakeRetainedWindowEnvironment()
        timeoutFailureEnvironment.timeoutConfigurationSucceeds = false
        assertCaptureError(
            .timeoutConfigurationFailed,
            in: timeoutFailureEnvironment
        )
        XCTAssertEqual(timeoutFailureEnvironment.lastConfiguredTimeout, 0.75)
    }

    @MainActor
    func testRetainedWindowCaptureRequiresZedToBeFrontmost() {
        let environment = FakeRetainedWindowEnvironment()
        environment.currentFrontmostApplication = FakeCaptureApplication(
            processIdentifier: 83,
            bundleIdentifier: "com.example.other"
        )

        assertCaptureError(.zedNotFrontmost, in: environment)
    }

    @MainActor
    func testRetainedWindowCaptureRejectsMissingOrInvalidFocusedWindows() {
        let missingWindowEnvironment = FakeRetainedWindowEnvironment()
        missingWindowEnvironment.focusedWindow = nil
        assertCaptureError(
            .focusedWindowUnavailable,
            in: missingWindowEnvironment
        )

        let foreignWindowEnvironment = FakeRetainedWindowEnvironment()
        foreignWindowEnvironment.focusedWindow?.ownerProcessIdentifier = 83
        assertCaptureError(.invalidWindow, in: foreignWindowEnvironment)

        let nonWindowEnvironment = FakeRetainedWindowEnvironment()
        nonWindowEnvironment.focusedWindow?.role = "AXButton"
        assertCaptureError(.invalidWindow, in: nonWindowEnvironment)
    }

    @MainActor
    func testRetainedWindowCaptureRejectsFocusOrForegroundChanges() {
        let changedWindowEnvironment = FakeRetainedWindowEnvironment()
        changedWindowEnvironment.focusedWindowResponses = [
            changedWindowEnvironment.focusedWindow,
            FakeCaptureWindow(
                ownerProcessIdentifier: changedWindowEnvironment.zedApplication.processIdentifier,
                role: "AXWindow"
            ),
        ]
        assertCaptureError(
            .focusChangedDuringCapture,
            in: changedWindowEnvironment
        )

        let changedApplicationEnvironment = FakeRetainedWindowEnvironment()
        let otherApplication = FakeCaptureApplication(
            processIdentifier: 83,
            bundleIdentifier: "com.example.other"
        )
        changedApplicationEnvironment.frontmostApplicationResponses = [
            changedApplicationEnvironment.zedApplication,
            changedApplicationEnvironment.zedApplication,
            otherApplication,
        ]
        assertCaptureError(
            .focusChangedDuringCapture,
            in: changedApplicationEnvironment
        )
    }

    @MainActor
    func testRetainedSourceBecomesInvalidWhenItsWindowOrApplicationChanges() throws {
        let environment = FakeRetainedWindowEnvironment()
        let source = try RetainedWindowCaptureCoordinator(environment: environment).capture()
        XCTAssertTrue(source.isValid())

        environment.focusedWindow?.role = "AXButton"
        XCTAssertFalse(source.isValid())

        environment.focusedWindow?.role = "AXWindow"
        environment.zedApplication.terminated = true
        XCTAssertFalse(source.isValid())
    }

    @MainActor
    func testCompletionUsesTheSourceCapturedByItsBinding() throws {
        let leftSource = TestSourceWindow()
        let rightSource = TestSourceWindow()
        var sources = [leftSource, rightSource].makeIterator()
        var bindingIDs = ["binding_left", "binding_right"].makeIterator()
        var deliveredCompletions: [(TestSourceWindow, UInt64, UInt8)] = []

        let handler = NotificationRequestHandler<TestSourceWindow>(
            captureSource: { sources.next() },
            deliverCompletion: { source, elapsedMS, exitCode in
                deliveredCompletions.append((source, elapsedMS, exitCode))
            },
            makeBindingID: { try! XCTUnwrap(bindingIDs.next()) }
        )

        let leftBindingID = try bindingID(from: handler.handle(.bind))
        let rightBindingID = try bindingID(from: handler.handle(.bind))
        XCTAssertNotEqual(leftBindingID, rightBindingID)

        let response = handler.handle(
            .complete(bindingID: leftBindingID, elapsedMS: 31000, exitCode: 7)
        )

        XCTAssertEqual(response, .accepted)
        XCTAssertEqual(deliveredCompletions.count, 1)
        XCTAssertTrue(deliveredCompletions[0].0 === leftSource)
        XCTAssertEqual(deliveredCompletions[0].1, 31000)
        XCTAssertEqual(deliveredCompletions[0].2, 7)

        let rightResponse = handler.handle(
            .complete(bindingID: rightBindingID, elapsedMS: 42000, exitCode: 0)
        )
        XCTAssertEqual(rightResponse, .accepted)
        XCTAssertEqual(deliveredCompletions.count, 2)
        XCTAssertTrue(deliveredCompletions[1].0 === rightSource)
    }

    @MainActor
    func testBindReportsSourceUnavailableWhenCaptureFails() {
        let handler = NotificationRequestHandler<TestSourceWindow>(
            captureSource: { nil },
            deliverCompletion: { _, _, _ in
                XCTFail("No completion should be delivered without a binding")
            }
        )

        XCTAssertEqual(handler.handle(.bind), .error(.sourceUnavailable))
    }

    @MainActor
    func testCompletionRejectsUnknownBinding() {
        var delivered = false
        let handler = NotificationRequestHandler<TestSourceWindow>(
            captureSource: { TestSourceWindow() },
            deliverCompletion: { _, _, _ in delivered = true }
        )

        let response = handler.handle(
            .complete(bindingID: "unknown_binding", elapsedMS: 1, exitCode: 0)
        )

        XCTAssertEqual(response, .error(.unknownBinding))
        XCTAssertFalse(delivered)
    }

    @MainActor
    func testDuplicateGeneratedBindingIDDoesNotReplaceExistingSource() throws {
        let firstSource = TestSourceWindow()
        let secondSource = TestSourceWindow()
        var sources = [firstSource, secondSource].makeIterator()
        var bindingIDs = ["binding_shared", "binding_shared", "binding_next"].makeIterator()
        var deliveredSources: [TestSourceWindow] = []

        let handler = NotificationRequestHandler<TestSourceWindow>(
            captureSource: { sources.next() },
            deliverCompletion: { source, _, _ in deliveredSources.append(source) },
            makeBindingID: { try! XCTUnwrap(bindingIDs.next()) }
        )

        let firstBindingID = try bindingID(from: handler.handle(.bind))
        let secondBindingID = try bindingID(from: handler.handle(.bind))

        XCTAssertEqual(firstBindingID, "binding_shared")
        XCTAssertEqual(secondBindingID, "binding_next")
        XCTAssertEqual(
            handler.handle(.complete(bindingID: firstBindingID, elapsedMS: 1, exitCode: 0)),
            .accepted
        )
        XCTAssertTrue(deliveredSources.first === firstSource)
    }

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

    @MainActor
    private func assertCaptureError<Environment: RetainedWindowEnvironment>(
        _ expected: RetainedWindowCaptureError,
        in environment: Environment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let capture = RetainedWindowCaptureCoordinator(environment: environment)
        XCTAssertThrowsError(try capture.capture(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? RetainedWindowCaptureError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func bindingID(
        from response: NotificationProtocol.Response,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        guard case let .bound(bindingID) = response else {
            XCTFail("Expected a bound response", file: file, line: line)
            throw NotificationProtocolFailure.invalidResponse
        }
        return bindingID
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

private final class TestSourceWindow {}

@MainActor
private final class FakeCaptureApplication {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    var terminated = false

    init(processIdentifier: pid_t, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

@MainActor
private final class FakeCaptureWindow {
    var ownerProcessIdentifier: pid_t
    var role: String?

    init(ownerProcessIdentifier: pid_t, role: String?) {
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.role = role
    }
}

@MainActor
private final class FakeRetainedWindowEnvironment: RetainedWindowEnvironment {
    private(set) var lastConfiguredTimeout: Float?
    var accessibilityTrusted = true
    var timeoutConfigurationSucceeds = true
    var currentFrontmostApplication: FakeCaptureApplication?
    var focusedWindow: FakeCaptureWindow?
    var frontmostApplicationResponses: [FakeCaptureApplication?] = []
    var focusedWindowResponses: [FakeCaptureWindow?] = []
    let zedApplication = FakeCaptureApplication(
        processIdentifier: 41,
        bundleIdentifier: RetainedWindowCaptureCoordinator<FakeRetainedWindowEnvironment>
            .zedBundleIdentifier
    )

    init() {
        currentFrontmostApplication = zedApplication
        focusedWindow = FakeCaptureWindow(
            ownerProcessIdentifier: zedApplication.processIdentifier,
            role: "AXWindow"
        )
    }

    func accessibilityIsTrusted() -> Bool {
        accessibilityTrusted
    }

    func configureMessagingTimeout(_ timeout: Float) -> Bool {
        lastConfiguredTimeout = timeout
        return timeoutConfigurationSucceeds
    }

    func frontmostApplication() -> FakeCaptureApplication? {
        guard !frontmostApplicationResponses.isEmpty else {
            return currentFrontmostApplication
        }
        return frontmostApplicationResponses.removeFirst()
    }

    func bundleIdentifier(for application: FakeCaptureApplication) -> String? {
        application.bundleIdentifier
    }

    func isTerminated(_ application: FakeCaptureApplication) -> Bool {
        application.terminated
    }

    func processIdentifier(for application: FakeCaptureApplication) -> pid_t {
        application.processIdentifier
    }

    func focusedWindow(for application: FakeCaptureApplication) -> FakeCaptureWindow? {
        guard !focusedWindowResponses.isEmpty else {
            return focusedWindow
        }
        return focusedWindowResponses.removeFirst()
    }

    func ownerProcessIdentifier(of window: FakeCaptureWindow) -> pid_t? {
        window.ownerProcessIdentifier
    }

    func role(of window: FakeCaptureWindow) -> String? {
        window.role
    }

    func sameWindow(_ lhs: FakeCaptureWindow, _ rhs: FakeCaptureWindow) -> Bool {
        lhs === rhs
    }
}
