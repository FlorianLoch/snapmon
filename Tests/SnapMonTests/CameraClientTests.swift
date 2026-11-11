import XCTest

@testable import SnapMon

final class CameraClientTests: XCTestCase {
  func testRecoverySendsFreshStartWithoutStoppingFirst() async throws {
    let sender = RecordingCameraCommandSender()
    let client = CameraClient(
      printer: printer,
      commandSender: sender
    )

    try await client.startMonitoring()
    try await client.recoverMonitoring()

    let commands = await sender.recordedCommands()
    XCTAssertEqual(commands.map(\.command), [.start, .start])
    XCTAssertEqual(commands.map(\.requestID), [100, 101])
  }

  func testStopIsReservedForActuallyClosingTheCamera() async throws {
    let sender = RecordingCameraCommandSender()
    let client = CameraClient(
      printer: printer,
      commandSender: sender
    )

    try await client.startMonitoring()
    await client.stopMonitoring()

    let commands = await sender.recordedCommands()
    XCTAssertEqual(commands.map(\.command), [.start, .stop])
  }

  private var printer: SavedPrinter {
    SavedPrinter(
      name: "U1",
      host: "192.168.1.42",
      serialNumber: "U1-123"
    )
  }
}

private actor RecordingCameraCommandSender: CameraMonitorCommandSending {
  struct RecordedCommand: Sendable {
    let command: CameraMonitorCommand
    let requestID: Int
  }

  private var commands: [RecordedCommand] = []

  func send(
    _ command: CameraMonitorCommand,
    to printer: SavedPrinter,
    requestID: Int
  ) {
    commands.append(
      RecordedCommand(
        command: command,
        requestID: requestID
      )
    )
  }

  func recordedCommands() -> [RecordedCommand] {
    commands
  }
}
