import XCTest

@testable import SnapMon

final class PrinterStateReducerTests: XCTestCase {
  func testUsesGCodeByteRangeForProgressAndETA() {
    var reducer = PrinterStateReducer()

    reducer.apply(
      [
        "print_stats": .object([
          "state": .string("printing"),
          "filename": .string("part.gcode"),
          "print_duration": .number(300),
          "info": .object([
            "current_layer": .number(4),
            "total_layer": .number(20),
          ]),
        ]),
        "virtual_sdcard": .object([
          "progress": .number(0.75),
          "file_position": .number(300),
        ]),
      ]
    )
    reducer.setMetadata(
      GCodeMetadata(
        startByte: 100,
        endByte: 900,
        estimatedTime: 1_000
      ),
      for: "part.gcode"
    )

    XCTAssertEqual(reducer.snapshot.progress, 0.25, accuracy: 0.0001)
    XCTAssertEqual(reducer.snapshot.remaining, 750)
    XCTAssertEqual(reducer.snapshot.currentLayer, 4)
    XCTAssertEqual(reducer.snapshot.totalLayers, 20)
  }

  func testFallsBackToElapsedTimeEstimate() {
    var reducer = PrinterStateReducer()

    reducer.apply(
      [
        "print_stats": .object([
          "state": .string("printing"),
          "print_duration": .number(600),
        ]),
        "virtual_sdcard": .object([
          "progress": .number(0.5)
        ]),
      ]
    )

    XCTAssertEqual(reducer.snapshot.remaining, 600)
  }

  func testPartialUpdatesPreserveEarlierValues() {
    var reducer = PrinterStateReducer()

    reducer.apply(
      [
        "heater_bed": .object([
          "temperature": .number(55),
          "target": .number(60),
        ]),
        "toolhead": .object([
          "extruder": .string("extruder2")
        ]),
        "extruder2": .object([
          "temperature": .number(210),
          "target": .number(220),
        ]),
      ]
    )
    reducer.apply(
      [
        "print_stats": .object([
          "state": .string("paused")
        ])
      ]
    )

    XCTAssertEqual(reducer.snapshot.state, .paused)
    XCTAssertEqual(reducer.snapshot.bed.current, 55)
    XCTAssertEqual(reducer.snapshot.nozzle.target, 220)
  }

  func testReadsLEDColorData() {
    var reducer = PrinterStateReducer()

    reducer.apply(
      [
        "led cavity_led": .object([
          "color_data": .array([
            .array([.number(0), .number(0), .number(0), .number(1)])
          ])
        ])
      ]
    )

    XCTAssertTrue(reducer.snapshot.ledOn)
  }

  func testReadsSpeedModifier() {
    var reducer = PrinterStateReducer()

    reducer.apply(
      [
        "gcode_move": .object([
          "speed_factor": .number(1.2)
        ])
      ]
    )

    XCTAssertEqual(reducer.snapshot.speedModifier, 120)
  }

  func testSpeedModifierUsesRequestedDiscreteValues() {
    XCTAssertEqual(PrinterSpeedModifier.values, [50, 80, 100, 120, 150])
    XCTAssertEqual(PrinterSpeedModifier.defaultValue, 100)
    XCTAssertEqual(
      PrinterSpeedModifier.values.indices.map {
        PrinterSpeedModifier.value(at: Double($0))
      },
      PrinterSpeedModifier.values
    )
  }

  func testAppliesConfirmedLEDReadback() {
    var reducer = PrinterStateReducer()

    reducer.setLEDState(true)
    XCTAssertTrue(reducer.snapshot.ledOn)

    reducer.setLEDState(false)
    XCTAssertFalse(reducer.snapshot.ledOn)
  }

  func testCompleteStateHasZeroRemainingTime() {
    var reducer = PrinterStateReducer()

    reducer.apply(
      [
        "print_stats": .object([
          "state": .string("complete")
        ])
      ]
    )

    XCTAssertEqual(reducer.snapshot.remaining, 0)
  }

  func testCompletionDateIsAnchoredToSnapshotUpdate() {
    var snapshot = PrinterSnapshot()
    snapshot.updatedAt = Date(timeIntervalSince1970: 1_000)
    snapshot.remaining = 120

    XCTAssertEqual(
      snapshot.completionDate,
      Date(timeIntervalSince1970: 1_120)
    )
  }

  func testMetadataFetchCanRetryAfterFailure() {
    var tracker = MetadataFetchTracker()

    XCTAssertTrue(tracker.beginIfNeeded(for: "part.gcode"))
    XCTAssertFalse(tracker.beginIfNeeded(for: "part.gcode"))

    tracker.didFail(for: "part.gcode")

    XCTAssertTrue(tracker.beginIfNeeded(for: "part.gcode"))
  }
}
