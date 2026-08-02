import XCTest

@testable import SnapMon

final class CameraPreferencesTests: XCTestCase {
  func testClampsFrameRate() {
    XCTAssertEqual(CameraPreferences.clamp(0), 1)
    XCTAssertEqual(CameraPreferences.clamp(6.4), 6)
    XCTAssertEqual(CameraPreferences.clamp(99), 10)
  }

  func testCalculatesPollingInterval() {
    XCTAssertEqual(
      CameraPreferences.interval(for: 5),
      0.2,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      CameraPreferences.interval(for: 10),
      0.1,
      accuracy: 0.0001
    )
  }

  func testRekicksAnUnchangedFrozenStreamAndResetsAfterSuccess() async throws {
    let startedAt = Date(timeIntervalSince1970: 1_000)
    var controller = CameraRecoveryController(
      frozenFrameThreshold: 8
    )
    var performedReasons: [CameraRekickReason] = []

    let firstResult = await controller.rekickIfNeeded(
      frameIdentity: "frame-a",
      at: startedAt
    ) { reason in
      performedReasons.append(reason)
    }
    let earlyResult = await controller.rekickIfNeeded(
      frameIdentity: "frame-a",
      at: startedAt.addingTimeInterval(7)
    ) { reason in
      performedReasons.append(reason)
    }
    let frozenResult = await controller.rekickIfNeeded(
      frameIdentity: "frame-a",
      at: startedAt.addingTimeInterval(8)
    ) { reason in
      performedReasons.append(reason)
    }
    let resultAfterReset = await controller.rekickIfNeeded(
      frameIdentity: "frame-a",
      at: startedAt.addingTimeInterval(9)
    ) { reason in
      performedReasons.append(reason)
    }

    XCTAssertNil(firstResult)
    XCTAssertNil(earlyResult)
    XCTAssertEqual(frozenResult, .frozen)
    XCTAssertNil(resultAfterReset)
    XCTAssertEqual(performedReasons, [.frozen])
  }

  func testChangingFramesDoNotTriggerFrozenStreamRecovery() async {
    let startedAt = Date(timeIntervalSince1970: 2_000)
    var controller = CameraRecoveryController(
      frozenFrameThreshold: 8
    )
    var performedReasons: [CameraRekickReason] = []

    _ = await controller.rekickIfNeeded(
      frameIdentity: "frame-a",
      at: startedAt
    ) { reason in
      performedReasons.append(reason)
    }
    let result = await controller.rekickIfNeeded(
      frameIdentity: "frame-b",
      at: startedAt.addingTimeInterval(45)
    ) { reason in
      performedReasons.append(reason)
    }

    XCTAssertNil(result)
    XCTAssertTrue(performedReasons.isEmpty)
  }

  func testRetriesRekickWhenThePreviousAttemptFailed() async {
    enum TestError: Error {
      case failed
    }

    let startedAt = Date(timeIntervalSince1970: 3_000)
    var controller = CameraRecoveryController(
      frozenFrameThreshold: 8
    )
    var attemptCount = 0

    _ = await controller.rekickIfNeeded(
      frameIdentity: "frame-a",
      at: startedAt
    ) { _ in }
    _ = try? await controller.rekickIfNeeded(
      frameIdentity: "frame-a",
      at: startedAt.addingTimeInterval(8)
    ) { _ in
      attemptCount += 1
      throw TestError.failed
    }
    let retryResult = await controller.rekickIfNeeded(
      frameIdentity: "frame-a",
      at: startedAt.addingTimeInterval(9)
    ) { _ in
      attemptCount += 1
    }

    XCTAssertEqual(retryResult, .frozen)
    XCTAssertEqual(attemptCount, 2)
  }

  func testUsesFiveSecondDisposableWakeCadence() {
    XCTAssertEqual(CameraPreferences.monitorWakeInterval, 5)
  }
}
