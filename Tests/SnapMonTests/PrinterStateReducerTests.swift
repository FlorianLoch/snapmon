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
        "extruder": .object(["temperature": .number(24)]),
        "extruder1": .object(["temperature": .number(42)]),
        "extruder2": .object([
          "temperature": .number(210),
          "target": .number(220),
        ]),
        "extruder3": .object(["temperature": .number(31)]),
      ]
    )
    reducer.apply(
      [
        "print_stats": .object([
          "state": .string("paused")
        ]),
        "toolhead": .object(["extruder": .string("extruder3")]),
        "extruder2": .object(["temperature": .number(216)]),
      ]
    )

    XCTAssertEqual(reducer.snapshot.state, .paused)
    XCTAssertEqual(reducer.snapshot.bed.current, 55)
    XCTAssertEqual(reducer.snapshot.activeExtruder, "extruder3")
    XCTAssertEqual(reducer.snapshot.nozzles, [
      "extruder": TemperatureReading(current: 24),
      "extruder1": TemperatureReading(current: 42),
      "extruder2": TemperatureReading(current: 216, target: 220),
      "extruder3": TemperatureReading(current: 31),
    ])
  }

  func testReadsChamberAndVentilationAcrossPartialUpdates() {
    var reducer = PrinterStateReducer()

    reducer.apply([
      "temperature_sensor cavity": .object(["temperature": .number(36.2)]),
      "purifier": .object([
        "power_detected": .bool(true),
        "mode": .number(1),
        "exhaust_fan": .object(["speed": .number(0.7)]),
        "inner_fan": .object(["speed": .number(0.3)]),
        "inner_fan_rpm": .number(1_240),
      ]),
    ])

    XCTAssertEqual(reducer.snapshot.chamber.current, 36.2)
    XCTAssertEqual(reducer.snapshot.ventilation, VentilationReading(
      powerDetected: true,
      mode: .externalCirculation,
      exhaustSpeed: 0.7,
      recirculationSpeed: 0.3,
      recirculationRPM: 1_240
    ))

    reducer.apply([
      "purifier": .object([
        "mode": .number(2),
        "exhaust_fan": .object(["speed": .number(0)]),
      ]),
    ])

    XCTAssertEqual(reducer.snapshot.chamber.current, 36.2)
    XCTAssertEqual(reducer.snapshot.ventilation.mode, .internalPreheat)
    XCTAssertEqual(reducer.snapshot.ventilation.exhaustSpeed, 0)
    XCTAssertEqual(reducer.snapshot.ventilation.recirculationSpeed, 0.3)
    XCTAssertEqual(reducer.snapshot.ventilation.recirculationRPM, 1_240)

    reducer.apply(["purifier": .object(["mode": .number(3)])])
    XCTAssertEqual(reducer.snapshot.ventilation.mode, .internalCirculation)

    reducer.apply(["purifier": .object(["mode": .number(0), "inner_fan_rpm": .null])])
    XCTAssertEqual(reducer.snapshot.ventilation.mode, .standby)
    XCTAssertNil(reducer.snapshot.ventilation.recirculationRPM)

    reducer.apply(["purifier": .object(["power_detected": .bool(false)])])
    XCTAssertEqual(reducer.snapshot.ventilation.powerDetected, false)

    reducer.reset()
    XCTAssertNil(reducer.snapshot.chamber.current)
    XCTAssertEqual(reducer.snapshot.ventilation, VentilationReading())
  }

  func testFanSpeedsFollowModeAndFivePercentSteps() {
    var ventilation = VentilationReading(
      powerDetected: true, mode: .externalCirculation, exhaustSpeed: 0.6, recirculationSpeed: 0
    )

    XCTAssertEqual(ventilation.adjustableRange(for: .exhaust), 5...100)
    XCTAssertFalse(ventilation.allowsSpeed(0, for: .exhaust))
    XCTAssertTrue(ventilation.allowsSpeed(5, for: .exhaust))
    XCTAssertFalse(ventilation.allowsSpeed(6, for: .exhaust))
    XCTAssertTrue(ventilation.allowsSpeed(0, for: .recirculation))

    for mode in [VentilationMode.internalPreheat, .internalCirculation] {
      ventilation.mode = mode
      XCTAssertNil(ventilation.adjustableRange(for: .exhaust))
      XCTAssertEqual(ventilation.adjustableRange(for: .recirculation), 10...100)
    }

    ventilation.mode = .standby
    XCTAssertTrue(ventilation.allowsSpeed(0, for: .exhaust))
    ventilation.powerDetected = false
    XCTAssertNil(ventilation.adjustableRange(for: .recirculation))
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
