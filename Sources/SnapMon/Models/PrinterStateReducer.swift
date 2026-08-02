import Foundation

struct PrinterStateReducer {
  private(set) var snapshot = PrinterSnapshot()

  private var metadata: GCodeMetadata?
  private var metadataFilename: String?
  private var filePosition: Double?
  private var virtualProgress: Double?
  private var displayProgress: Double?
  private var extruderReadings: [String: TemperatureReading] = [:]

  mutating func reset() {
    self = PrinterStateReducer()
  }

  mutating func apply(
    _ objects: [String: JSONValue],
    at date: Date = Date()
  ) {
    if let printStats = objects["print_stats"]?.objectValue {
      applyPrintStats(printStats)
    }

    if let displayStatus = objects["display_status"]?.objectValue {
      displayProgress = displayStatus["progress"]?.doubleValue
      snapshot.message = displayStatus["message"]?.stringValue ?? snapshot.message
    }

    if let virtualSD = objects["virtual_sdcard"]?.objectValue {
      virtualProgress = virtualSD["progress"]?.doubleValue
      filePosition = virtualSD["file_position"]?.doubleValue
    }

    if let heaterBed = objects["heater_bed"]?.objectValue {
      snapshot.bed = temperature(from: heaterBed, previous: snapshot.bed)
    }

    if let toolhead = objects["toolhead"]?.objectValue,
      let activeExtruder = toolhead["extruder"]?.stringValue
    {
      snapshot.activeExtruder = activeExtruder
    }

    for name in ["extruder", "extruder1", "extruder2", "extruder3"] {
      guard let status = objects[name]?.objectValue else {
        continue
      }

      extruderReadings[name] = temperature(
        from: status,
        previous: extruderReadings[name] ?? TemperatureReading()
      )
    }

    snapshot.nozzle = extruderReadings[snapshot.activeExtruder] ?? snapshot.nozzle

    if let led = objects["led cavity_led"]?.objectValue,
      let colors = led["color_data"]?.arrayValue
    {
      snapshot.ledOn =
        colors
        .flatMap { $0.arrayValue ?? [$0] }
        .compactMap(\.doubleValue)
        .contains { $0 > 0.01 }
    }

    recalculateProgress()
    snapshot.updatedAt = date
  }

  mutating func setMetadata(
    _ metadata: GCodeMetadata?,
    for filename: String
  ) {
    guard filename == snapshot.filename else {
      return
    }

    self.metadata = metadata
    metadataFilename = filename
    recalculateProgress()
  }

  mutating func setLEDState(_ isOn: Bool) {
    snapshot.ledOn = isOn
    snapshot.updatedAt = Date()
  }

  private mutating func applyPrintStats(_ status: [String: JSONValue]) {
    if let state = status["state"]?.stringValue {
      snapshot.state = PrintState(moonrakerValue: state)
    }

    if let filename = status["filename"]?.stringValue, filename != snapshot.filename {
      snapshot.filename = filename
      metadata = nil
      metadataFilename = nil
    }

    snapshot.elapsed = status["print_duration"]?.doubleValue ?? snapshot.elapsed
    snapshot.message = status["message"]?.stringValue ?? snapshot.message

    if let info = status["info"]?.objectValue {
      snapshot.currentLayer = info["current_layer"]?.intValue ?? snapshot.currentLayer
      snapshot.totalLayers = info["total_layer"]?.intValue ?? snapshot.totalLayers
    }
  }

  private func temperature(
    from status: [String: JSONValue],
    previous: TemperatureReading
  ) -> TemperatureReading {
    TemperatureReading(
      current: status["temperature"]?.doubleValue ?? previous.current,
      target: status["target"]?.doubleValue ?? previous.target
    )
  }

  private mutating func recalculateProgress() {
    let calculatedProgress: Double

    if metadataFilename == snapshot.filename,
      let metadata,
      let start = metadata.startByte,
      let end = metadata.endByte,
      let position = filePosition,
      end > start
    {
      calculatedProgress = (position - start) / (end - start)
    } else if let virtualProgress {
      calculatedProgress = virtualProgress
    } else {
      calculatedProgress = displayProgress ?? snapshot.progress
    }

    snapshot.progress = min(max(calculatedProgress, 0), 1)

    if snapshot.state == .complete {
      snapshot.remaining = 0
    } else if let estimatedTime = metadata?.estimatedTime {
      snapshot.remaining = max(0, estimatedTime * (1 - snapshot.progress))
    } else if snapshot.progress > 0.01 {
      snapshot.remaining = max(0, snapshot.elapsed / snapshot.progress - snapshot.elapsed)
    } else {
      snapshot.remaining = nil
    }
  }
}
