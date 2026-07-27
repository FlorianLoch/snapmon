import XCTest

@testable import SnapmakerMonitor

final class CompletionTrackerTests: XCTestCase {
  private let printer = SavedPrinter(
    name: "Workshop U1",
    host: "192.168.1.42",
    serialNumber: "U1-123",
    firmwareVersion: "1.5.0"
  )

  func testDoesNotNotifyForCompleteStateAtStartup() {
    var tracker = CompletionTracker()
    var snapshot = PrinterSnapshot()
    snapshot.state = .complete
    snapshot.filename = "old.gcode"

    XCTAssertNil(tracker.observe(snapshot, printer: printer))
  }

  func testNotifiesOnceAfterObservedActivePrint() {
    var tracker = CompletionTracker()
    var snapshot = PrinterSnapshot()
    let start = Date(timeIntervalSince1970: 1_000)

    snapshot.state = .printing
    snapshot.filename = "part.gcode"
    XCTAssertNil(tracker.observe(snapshot, printer: printer, now: start))

    snapshot.state = .complete
    let event = tracker.observe(snapshot, printer: printer, now: start.addingTimeInterval(50))

    XCTAssertEqual(event?.job.filename, "part.gcode")
    XCTAssertEqual(event?.job.observedStart, start)
    XCTAssertNil(tracker.observe(snapshot, printer: printer))
  }

  func testPausedPrintRemainsActiveAcrossReconnect() {
    var tracker = CompletionTracker()
    var snapshot = PrinterSnapshot()

    snapshot.state = .printing
    snapshot.filename = "part.gcode"
    XCTAssertNil(tracker.observe(snapshot, printer: printer))

    snapshot.state = .paused
    XCTAssertNil(tracker.observe(snapshot, printer: printer))

    snapshot.state = .complete
    XCTAssertNotNil(tracker.observe(snapshot, printer: printer))
  }
}
