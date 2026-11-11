import AppKit
import XCTest

@testable import SnapMon

@MainActor
final class AppModelLifecycleTests: XCTestCase {
  func testRestoresSavedPrinterWithoutDisplayingCachedFirmware() {
    let defaults = isolatedDefaults()
    let savedPrinter = """
      {"name":"U1","host":"127.0.0.1","serialNumber":"U1-123","firmwareVersion":"1.5.1"}
      """
    defaults.set(Data(savedPrinter.utf8), forKey: "selected_printer")

    let model = AppModel(defaults: defaults)

    XCTAssertEqual(model.selectedPrinter?.serialNumber, "U1-123")
    XCTAssertEqual(model.selectedPrinter?.host, "127.0.0.1")
    XCTAssertNil(model.firmwareVersion)
  }

  func testPrinterSwitchClearsPendingCommandAndRejectsOldCommandResults() {
    let model = AppModel(defaults: isolatedDefaults())
    let previousPrinter = printer(serial: "old", host: "127.0.0.1")
    let replacementPrinter = printer(serial: "new", host: "127.0.0.2")
    model.selectedPrinter = previousPrinter
    model.isCommandPending = true

    model.select(replacementPrinter)
    model.applyConfirmedLEDState(true, for: previousPrinter)
    model.applyConfirmedSpeedModifier(150, for: previousPrinter)

    XCTAssertFalse(model.isCommandPending)
    XCTAssertFalse(model.snapshot.ledOn)
    XCTAssertEqual(model.snapshot.speedModifier, 100)
    model.shutdown()
  }

  func testCameraReplacementWaitsForPreviousStop() async {
    let recorder = CameraLifecycleRecorder()
    let firstStopGate = CameraStopGate()
    var createdClientCount = 0
    let model = AppModel(
      defaults: isolatedDefaults(),
      cameraClientFactory: { _ in
        createdClientCount += 1
        return RecordingCameraSessionClient(
          id: createdClientCount,
          recorder: recorder,
          stopGate: createdClientCount == 1 ? firstStopGate : nil
        )
      }
    )
    model.selectedPrinter = printer(serial: "printer", host: "127.0.0.1")

    model.setCameraVisible(true)
    let firstCameraStarted = await waitUntil {
      await recorder.contains("start-1")
    }
    XCTAssertTrue(firstCameraStarted)

    model.setCameraVisible(false)
    model.setCameraVisible(true)
    let firstCameraStopBegan = await waitUntil {
      await recorder.contains("stop-begin-1")
    }
    XCTAssertTrue(firstCameraStopBegan)
    XCTAssertEqual(createdClientCount, 1)
    let replacementStartedBeforeStopFinished = await recorder.contains("start-2")
    XCTAssertFalse(replacementStartedBeforeStopFinished)

    await firstStopGate.release()

    let replacementCameraStarted = await waitUntil {
      await recorder.contains("start-2")
    }
    XCTAssertTrue(replacementCameraStarted)
    let events = await recorder.events()
    guard
      let stopIndex = events.firstIndex(of: "stop-end-1"),
      let startIndex = events.firstIndex(of: "start-2")
    else {
      XCTFail("Expected both the completed stop and replacement start events")
      return
    }
    XCTAssertLessThan(stopIndex, startIndex)
    model.shutdown()
  }

  func testPrinterSwitchClearsPreviousCameraFrame() async {
    let recorder = CameraLifecycleRecorder()
    let model = AppModel(
      defaults: isolatedDefaults(),
      cameraClientFactory: { _ in
        RecordingCameraSessionClient(
          id: 1,
          recorder: recorder,
          stopGate: nil
        )
      }
    )
    model.selectedPrinter = printer(serial: "old", host: "127.0.0.1")
    model.setCameraVisible(true)
    let cameraStarted = await waitUntil {
      await recorder.contains("start-1")
    }
    XCTAssertTrue(cameraStarted)
    model.cameraImage = NSImage(size: NSSize(width: 2, height: 2))
    model.cameraFrameDate = Date()

    model.select(printer(serial: "new", host: "127.0.0.2"))

    XCTAssertNil(model.cameraImage)
    XCTAssertNil(model.cameraFrameDate)
    model.shutdown()
  }

  private func printer(serial: String, host: String) -> SavedPrinter {
    SavedPrinter(
      name: "U1",
      host: host,
      serialNumber: serial
    )
  }

  private func isolatedDefaults() -> UserDefaults {
    let suiteName = "AppModelLifecycleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool
  ) async -> Bool {
    for _ in 0..<100 {
      if await condition() {
        return true
      }

      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return false
  }
}

private actor CameraLifecycleRecorder {
  private var recordedEvents: [String] = []

  func record(_ event: String) {
    recordedEvents.append(event)
  }

  func contains(_ event: String) -> Bool {
    recordedEvents.contains(event)
  }

  func events() -> [String] {
    recordedEvents
  }
}

private actor CameraStopGate {
  private var isReleased = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    if isReleased {
      return
    }

    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release() {
    isReleased = true
    continuation?.resume()
    continuation = nil
  }
}

private actor RecordingCameraSessionClient: CameraSessionClient {
  let id: Int
  let recorder: CameraLifecycleRecorder
  let stopGate: CameraStopGate?

  init(
    id: Int,
    recorder: CameraLifecycleRecorder,
    stopGate: CameraStopGate?
  ) {
    self.id = id
    self.recorder = recorder
    self.stopGate = stopGate
  }

  func startMonitoring() async throws {
    await recorder.record("start-\(id)")
  }

  func frame() async throws -> CameraFrame {
    throw MonitorError.invalidResponse
  }

  func recoverMonitoring() async throws {}

  func stopMonitoring() async {
    await recorder.record("stop-begin-\(id)")
    await stopGate?.wait()
    await recorder.record("stop-end-\(id)")
  }
}
