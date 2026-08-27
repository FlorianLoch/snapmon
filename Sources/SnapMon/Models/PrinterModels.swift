import Foundation

enum ConnectionState: Equatable, Sendable {
  case disconnected
  case connecting
  case connected
  case stale(String)

  var label: String {
    switch self {
    case .disconnected:
      return "Offline"
    case .connecting:
      return "Connecting"
    case .connected:
      return "Online"
    case .stale:
      return "Reconnecting"
    }
  }

  var isConnected: Bool {
    self == .connected
  }
}

enum PrintState: String, Codable, CaseIterable, Sendable {
  case standby
  case printing
  case paused
  case complete
  case error
  case cancelled
  case unknown

  init(moonrakerValue: String?) {
    self = PrintState(rawValue: moonrakerValue?.lowercased() ?? "") ?? .unknown
  }

  var displayName: String {
    switch self {
    case .standby:
      return "Ready"
    case .printing:
      return "Printing"
    case .paused:
      return "Paused"
    case .complete:
      return "Complete"
    case .error:
      return "Error"
    case .cancelled:
      return "Cancelled"
    case .unknown:
      return "Unknown"
    }
  }

  var isActive: Bool {
    self == .printing || self == .paused
  }
}

struct DiscoveredDevice: Identifiable, Hashable, Codable, Sendable {
  let id: String
  let name: String
  let host: String
  let serialNumber: String
  let firmwareVersion: String?
  let serviceName: String

  static func fromBonjour(
    serviceName: String,
    txt: [String: String]
  ) -> DiscoveredDevice? {
    guard txt["machine_type"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "Snapmaker U1",
      txt["link_mode"]?.lowercased() == "lan",
      let host = txt["ip"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !host.isEmpty
    else {
      return nil
    }

    let serial = txt["sn"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let stableID = serial.flatMap { $0.isEmpty ? nil : $0 } ?? serviceName
    let deviceName = txt["device_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)

    return DiscoveredDevice(
      id: stableID,
      name: deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? serviceName,
      host: host,
      serialNumber: serial ?? "",
      firmwareVersion: txt["version"],
      serviceName: serviceName
    )
  }

  var savedPrinter: SavedPrinter {
    SavedPrinter(
      name: name,
      host: host,
      serialNumber: serialNumber.isEmpty ? id : serialNumber,
      firmwareVersion: firmwareVersion
    )
  }

  func matches(_ printer: SavedPrinter) -> Bool {
    id == printer.serialNumber
  }
}

struct SavedPrinter: Codable, Equatable, Sendable {
  let name: String
  let host: String
  let serialNumber: String
  let firmwareVersion: String?

  var id: String {
    serialNumber
  }
}

struct GCodeMetadata: Equatable, Sendable {
  let startByte: Double?
  let endByte: Double?
  let estimatedTime: TimeInterval?
}

struct TemperatureReading: Equatable, Sendable {
  var current: Double?
  var target: Double?
}

enum PrinterSpeedModifier {
  static let values = [50, 80, 100, 120, 150]
  static let defaultValue = 100

  static func closestIndex(to value: Int) -> Int {
    values.indices.min {
      abs(values[$0] - value) < abs(values[$1] - value)
    } ?? values.startIndex
  }

  static func value(at index: Double) -> Int {
    let roundedIndex = Int(index.rounded())
    let clampedIndex = min(
      max(roundedIndex, values.startIndex), values.index(before: values.endIndex))
    return values[clampedIndex]
  }
}

struct PrinterSnapshot: Equatable, Sendable {
  var state: PrintState = .unknown
  var filename = ""
  var message = ""
  var progress = 0.0
  var elapsed: TimeInterval = 0
  var remaining: TimeInterval?
  var currentLayer: Int?
  var totalLayers: Int?
  var bed = TemperatureReading()
  var nozzle = TemperatureReading()
  var activeExtruder = "extruder"
  var speedModifier = PrinterSpeedModifier.defaultValue
  var ledOn = false
  var updatedAt: Date?

  var completionDate: Date? {
    guard let remaining, let updatedAt else {
      return nil
    }

    return updatedAt.addingTimeInterval(remaining)
  }
}

struct JobIdentity: Hashable, Sendable {
  let printerSerial: String
  let filename: String
  let observedStart: Date
}

struct CompletionEvent: Equatable, Sendable {
  let job: JobIdentity
  let printerName: String
}

struct CompletionTracker: Sendable {
  private(set) var activeJob: JobIdentity?
  private(set) var lastNotifiedJob: JobIdentity?

  mutating func observe(
    _ snapshot: PrinterSnapshot,
    printer: SavedPrinter,
    now: Date = Date()
  ) -> CompletionEvent? {
    if snapshot.state.isActive {
      if activeJob == nil {
        activeJob = JobIdentity(
          printerSerial: printer.serialNumber,
          filename: snapshot.filename,
          observedStart: now
        )
      } else if activeJob?.printerSerial != printer.serialNumber
        || (!snapshot.filename.isEmpty
          && activeJob?.filename != snapshot.filename)
      {
        let preservesObservedStart =
          activeJob?.printerSerial == printer.serialNumber
          && activeJob?.filename.isEmpty == true
        activeJob = JobIdentity(
          printerSerial: printer.serialNumber,
          filename: snapshot.filename,
          observedStart: preservesObservedStart
            ? activeJob?.observedStart ?? now
            : now
        )
      }

      return nil
    }

    guard snapshot.state == .complete,
      let job = activeJob,
      lastNotifiedJob != job
    else {
      if snapshot.state == .standby || snapshot.state == .cancelled || snapshot.state == .error {
        activeJob = nil
      }

      return nil
    }

    activeJob = nil
    lastNotifiedJob = job
    return CompletionEvent(job: job, printerName: printer.name)
  }
}

struct MetadataFetchTracker: Sendable {
  private(set) var filename: String?

  mutating func beginIfNeeded(for filename: String) -> Bool {
    guard !filename.isEmpty, self.filename != filename else {
      return false
    }

    self.filename = filename
    return true
  }

  mutating func didFail(for filename: String) {
    if self.filename == filename {
      self.filename = nil
    }
  }

  mutating func reset() {
    filename = nil
  }
}

enum CameraPreferences {
  static let minimumFrameRate = 1.0
  static let maximumFrameRate = 10.0
  static let defaultFrameRate = 5.0
  static let frozenFrameThreshold: TimeInterval = 8
  static let monitorWakeInterval: TimeInterval = 5

  static func clamp(_ value: Double) -> Double {
    min(max(value.rounded(), minimumFrameRate), maximumFrameRate)
  }

  static func interval(for frameRate: Double) -> TimeInterval {
    1.0 / clamp(frameRate)
  }
}

enum CameraRekickReason: Equatable, Sendable {
  case frozen
}

struct CameraRecoveryController: Sendable {
  private let frozenFrameThreshold: TimeInterval
  private var lastFrameIdentity: String?
  private var lastFrameChangeAt: Date?

  init(
    frozenFrameThreshold: TimeInterval = CameraPreferences.frozenFrameThreshold
  ) {
    self.frozenFrameThreshold = frozenFrameThreshold
  }

  mutating func rekickIfNeeded(
    frameIdentity: String,
    at date: Date,
    performRekick: (CameraRekickReason) async throws -> Void
  ) async rethrows -> CameraRekickReason? {
    let reason = recoveryReason(frameIdentity: frameIdentity, at: date)

    guard let reason else {
      return nil
    }

    try await performRekick(reason)
    didRekick()
    return reason
  }

  mutating func didRekick() {
    lastFrameIdentity = nil
    lastFrameChangeAt = nil
  }

  private mutating func recoveryReason(
    frameIdentity: String,
    at date: Date
  ) -> CameraRekickReason? {
    if lastFrameIdentity == frameIdentity {
      if let lastFrameChangeAt,
        date.timeIntervalSince(lastFrameChangeAt) >= frozenFrameThreshold
      {
        return .frozen
      }
    } else {
      lastFrameIdentity = frameIdentity
      lastFrameChangeAt = date
    }

    return nil
  }
}

enum MonitorIntervals {
  static let printerStatusRefresh: TimeInterval = 2
  static let connectionStaleAfter: TimeInterval = 5
}

enum MonitorError: LocalizedError {
  case invalidAddress
  case invalidResponse
  case wrongPrinterModel(String)
  case server(String)
  case unauthorized

  var errorDescription: String? {
    switch self {
    case .invalidAddress:
      return "Enter a valid local IP address."
    case .invalidResponse:
      return "The printer returned an unexpected response."
    case .wrongPrinterModel(let model):
      return "This app supports only the Snapmaker U1, not \(model)."
    case .server(let message):
      return message
    case .unauthorized:
      return
        "The printer did not authorize local Moonraker access. Confirm that LAN mode is enabled."
    }
  }
}
