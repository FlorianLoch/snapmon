import Darwin
import Foundation

final class MoonrakerClient: @unchecked Sendable {
  private let printer: SavedPrinter
  private let session: URLSession

  init(printer: SavedPrinter, session: URLSession? = nil) {
    self.printer = printer

    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 10
      configuration.timeoutIntervalForResource = 20
      configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      self.session = URLSession(configuration: configuration)
    }
  }

  static func probe(host input: String) async throws -> SavedPrinter {
    let host = try normalizedIPAddress(input)
    let placeholder = SavedPrinter(
      name: host,
      host: host,
      serialNumber: host,
      firmwareVersion: nil
    )
    let client = MoonrakerClient(printer: placeholder)
    let response = try await client.get(path: "/machine/system_info")

    guard
      let productInfo =
        response
        .value(at: "result", "system_info", "product_info")?
        .objectValue
    else {
      throw MonitorError.invalidResponse
    }

    let model =
      productInfo["machine_type"]?.stringValue
      ?? productInfo["model"]?.stringValue
      ?? "Unknown printer"

    guard model == "Snapmaker U1" else {
      throw MonitorError.wrongPrinterModel(model)
    }

    let name =
      productInfo["device_name"]?.stringValue
      ?? productInfo["name"]?.stringValue
      ?? "Snapmaker U1"
    let serial =
      productInfo["serial_number"]?.stringValue
      ?? productInfo["sn"]?.stringValue
      ?? host
    let firmware =
      productInfo["firmware_version"]?.stringValue
      ?? productInfo["version"]?.stringValue

    return SavedPrinter(
      name: name,
      host: host,
      serialNumber: serial,
      firmwareVersion: firmware
    )
  }

  func statusUpdates() -> AsyncThrowingStream<[String: JSONValue], Error> {
    AsyncThrowingStream { continuation in
      do {
        let url = try websocketURL()
        let task = session.webSocketTask(with: url)

        continuation.onTermination = { _ in
          task.cancel(with: .goingAway, reason: nil)
        }

        task.resume()

        Task {
          do {
            try await Self.send(
              [
                "jsonrpc": "2.0",
                "method": "server.connection.identify",
                "params": [
                  "client_name": "SnapMon",
                  "version": "1.0",
                  "type": "other",
                  "url": "https://github.com/Snapmaker",
                ],
                "id": 1,
              ],
              to: task
            )

            try await Self.send(
              [
                "jsonrpc": "2.0",
                "method": "printer.objects.subscribe",
                "params": [
                  "objects": [
                    "print_stats": [
                      "state",
                      "filename",
                      "print_duration",
                      "total_duration",
                      "message",
                      "info",
                    ],
                    "display_status": ["progress", "message"],
                    "virtual_sdcard": [
                      "progress",
                      "file_position",
                      "file_size",
                    ],
                    "heater_bed": ["temperature", "target"],
                    "toolhead": ["extruder"],
                    "extruder": ["temperature", "target"],
                    "extruder1": ["temperature", "target"],
                    "extruder2": ["temperature", "target"],
                    "extruder3": ["temperature", "target"],
                    "led cavity_led": ["color_data"],
                  ]
                ],
                "id": 2,
              ],
              to: task
            )

            while !Task.isCancelled {
              let message = try await task.receive()
              let data: Data

              switch message {
              case .data(let value):
                data = value
              case .string(let value):
                data = Data(value.utf8)
              @unknown default:
                continue
              }

              let root = try JSONDecoder().decode(JSONValue.self, from: data)

              if let error = root["error"]?.objectValue,
                root["id"]?.intValue == 2
              {
                let message =
                  error["message"]?.stringValue
                  ?? "Moonraker rejected the status subscription."
                throw MonitorError.server(message)
              }

              if let status = Self.statusObjects(from: root) {
                continuation.yield(status)
              }
            }

            continuation.finish()
          } catch is CancellationError {
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }

  func metadata(for filename: String) async throws -> GCodeMetadata {
    let response = try await get(
      path: "/server/files/metadata",
      queryItems: [URLQueryItem(name: "filename", value: filename)]
    )
    guard let result = response["result"]?.objectValue else {
      throw MonitorError.invalidResponse
    }

    return GCodeMetadata(
      startByte: result["gcode_start_byte"]?.doubleValue,
      endByte: result["gcode_end_byte"]?.doubleValue,
      estimatedTime: result["estimated_time"]?.doubleValue
    )
  }

  func currentStatus() async throws -> [String: JSONValue] {
    let response = try await get(
      path: "/printer/objects/query",
      queryItems: [
        URLQueryItem(
          name: "print_stats",
          value: "state,filename,print_duration,total_duration,message,info"
        ),
        URLQueryItem(name: "display_status", value: "progress,message"),
        URLQueryItem(
          name: "virtual_sdcard",
          value: "progress,file_position,file_size"
        ),
        URLQueryItem(name: "heater_bed", value: "temperature,target"),
        URLQueryItem(name: "toolhead", value: "extruder"),
        URLQueryItem(name: "extruder", value: "temperature,target"),
        URLQueryItem(name: "extruder1", value: "temperature,target"),
        URLQueryItem(name: "extruder2", value: "temperature,target"),
        URLQueryItem(name: "extruder3", value: "temperature,target"),
        URLQueryItem(name: "led cavity_led", value: "color_data"),
      ]
    )
    guard let status = response.value(at: "result", "status")?.objectValue else {
      throw MonitorError.invalidResponse
    }

    return status
  }

  func pause() async throws {
    _ = try await request(path: "/printer/print/pause", method: "POST")
  }

  func resume() async throws {
    _ = try await request(path: "/printer/print/resume", method: "POST")
  }

  func setLED(on: Bool) async throws -> Bool {
    let script = "SET_LED LED=cavity_led WHITE=\(on ? 1 : 0)"
    _ = try await request(
      path: "/printer/gcode/script",
      method: "POST",
      body: ["script": script]
    )

    for attempt in 0..<5 {
      let currentState = try await ledState()

      if currentState == on {
        return currentState
      }

      if attempt < 4 {
        try await Task.sleep(nanoseconds: 150_000_000)
      }
    }

    throw MonitorError.server("The printer did not confirm the requested LED state.")
  }

  private func ledState() async throws -> Bool {
    let response = try await get(
      path: "/printer/objects/query",
      queryItems: [
        URLQueryItem(name: "led cavity_led", value: "color_data")
      ]
    )
    guard
      let colors =
        response
        .value(at: "result", "status", "led cavity_led", "color_data")?
        .arrayValue
    else {
      throw MonitorError.invalidResponse
    }

    return
      colors
      .flatMap { $0.arrayValue ?? [$0] }
      .compactMap(\.doubleValue)
      .contains { $0 > 0.01 }
  }

  private func get(
    path: String,
    queryItems: [URLQueryItem] = []
  ) async throws -> JSONValue {
    try await request(path: path, queryItems: queryItems)
  }

  private func request(
    path: String,
    method: String = "GET",
    queryItems: [URLQueryItem] = [],
    body: [String: Any]? = nil
  ) async throws -> JSONValue {
    let url = try httpURL(path: path, queryItems: queryItems)
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MonitorError.invalidResponse
    }

    if response.statusCode == 401 || response.statusCode == 403 {
      throw MonitorError.unauthorized
    }

    guard (200..<300).contains(response.statusCode) else {
      throw MonitorError.server(
        HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
      )
    }

    if data.isEmpty {
      return .null
    }

    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private func httpURL(
    path: String,
    queryItems: [URLQueryItem] = []
  ) throws -> URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = printer.host
    components.port = 80
    components.path = path
    components.queryItems = queryItems.isEmpty ? nil : queryItems

    guard let url = components.url else {
      throw MonitorError.invalidAddress
    }

    return url
  }

  private func websocketURL() throws -> URL {
    var components = URLComponents()
    components.scheme = "ws"
    components.host = printer.host
    components.port = 80
    components.path = "/websocket"

    guard let url = components.url else {
      throw MonitorError.invalidAddress
    }

    return url
  }

  private static func send(
    _ object: [String: Any],
    to task: URLSessionWebSocketTask
  ) async throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    try await task.send(.data(data))
  }

  private static func statusObjects(
    from root: JSONValue
  ) -> [String: JSONValue]? {
    if let status = root.value(at: "result", "status")?.objectValue {
      return status
    }

    guard root["method"]?.stringValue == "notify_status_update",
      let firstParameter = root["params"]?.arrayValue?.first
    else {
      return nil
    }

    return firstParameter.objectValue
  }

  private static func normalizedIPAddress(_ input: String) throws -> String {
    var candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)

    if let url = URL(string: candidate),
      let scheme = url.scheme,
      ["http", "https"].contains(scheme.lowercased()),
      let host = url.host
    {
      candidate = host
    }

    candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    let isIPv4 = candidate.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
    let isIPv6 = candidate.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }

    guard isIPv4 || isIPv6 else {
      throw MonitorError.invalidAddress
    }

    return candidate
  }
}

struct CameraFrame: Sendable {
  let data: Data
  let identity: String
}

enum CameraMonitorCommand: Equatable, Sendable {
  case start
  case stop

  var method: String {
    switch self {
    case .start:
      return "camera.start_monitor"
    case .stop:
      return "camera.stop_monitor"
    }
  }
}

protocol CameraMonitorCommandSending: Sendable {
  func send(
    _ command: CameraMonitorCommand,
    to printer: SavedPrinter,
    requestID: Int
  ) async throws
}

struct DisposableWebSocketCameraMonitorCommandSender: CameraMonitorCommandSending {
  private let timeout: TimeInterval
  private let closeDelay: TimeInterval

  init(
    timeout: TimeInterval = 3,
    closeDelay: TimeInterval = 0.25
  ) {
    self.timeout = timeout
    self.closeDelay = closeDelay
  }

  func send(
    _ command: CameraMonitorCommand,
    to printer: SavedPrinter,
    requestID: Int
  ) async throws {
    let session = makeSession()
    let task = session.webSocketTask(with: try websocketURL(for: printer))
    let operation = CameraWebSocketCommandOperation(
      session: session,
      task: task
    )
    let data = try JSONSerialization.data(
      withJSONObject: payload(for: command, requestID: requestID)
    )

    try await operation.execute(
      message: .data(data),
      timeout: timeout,
      closeDelay: closeDelay
    )
  }

  private func payload(
    for command: CameraMonitorCommand,
    requestID: Int
  ) -> [String: Any] {
    var params: [String: Any] = [
      "domain": "lan",
      "req_id": requestID,
    ]

    if command == .start {
      params["interval"] = 0
      params["expect_pw"] = false
    }

    return [
      "jsonrpc": "2.0",
      "method": command.method,
      "params": params,
      "id": requestID,
    ]
  }

  private func websocketURL(for printer: SavedPrinter) throws -> URL {
    var components = URLComponents()
    components.scheme = "ws"
    components.host = printer.host
    components.port = 80
    components.path = "/websocket"

    guard let url = components.url else {
      throw MonitorError.invalidAddress
    }

    return url
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }
}

private final class CameraWebSocketCommandOperation: @unchecked Sendable {
  private let lock = NSLock()
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private var continuation: CheckedContinuation<Void, Error>?
  private var result: Result<Void, Error>?

  init(
    session: URLSession,
    task: URLSessionWebSocketTask
  ) {
    self.session = session
    self.task = task
  }

  func execute(
    message: URLSessionWebSocketTask.Message,
    timeout: TimeInterval,
    closeDelay: TimeInterval
  ) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard install(continuation) else {
          return
        }

        task.resume()
        task.send(message) { [self] error in
          if let error {
            finish(with: .failure(error))
            return
          }

          DispatchQueue.global().asyncAfter(
            deadline: .now() + closeDelay
          ) { [self] in
            finish(with: .success(()))
          }
        }

        DispatchQueue.global().asyncAfter(
          deadline: .now() + timeout
        ) { [self] in
          finish(with: .failure(URLError(.timedOut)))
        }
      }
    } onCancel: {
      self.finish(with: .failure(CancellationError()))
    }
  }

  private func install(
    _ continuation: CheckedContinuation<Void, Error>
  ) -> Bool {
    lock.lock()

    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return false
    }

    self.continuation = continuation
    lock.unlock()
    return true
  }

  private func finish(with result: Result<Void, Error>) {
    lock.lock()

    guard self.result == nil else {
      lock.unlock()
      return
    }

    self.result = result
    let continuation = continuation
    self.continuation = nil
    lock.unlock()

    switch result {
    case .success:
      task.cancel(with: .normalClosure, reason: nil)
    case .failure:
      task.cancel(with: .goingAway, reason: nil)
    }

    session.invalidateAndCancel()
    continuation?.resume(with: result)
  }
}

protocol CameraSessionClient: AnyObject, Sendable {
  func startMonitoring() async throws
  func frame() async throws -> CameraFrame
  func recoverMonitoring() async throws
  func stopMonitoring() async
}

actor CameraClient: CameraSessionClient {
  private let printer: SavedPrinter
  private let commandSender: any CameraMonitorCommandSending
  private var frameSession: URLSession
  private var activeFrameTask: Task<(Data, URLResponse), Error>?
  private var activeFrameRequestID: UUID?
  private var nextRequestID = 100

  init(
    printer: SavedPrinter,
    commandSender: any CameraMonitorCommandSending =
      DisposableWebSocketCameraMonitorCommandSender()
  ) {
    self.printer = printer
    self.commandSender = commandSender
    frameSession = Self.makeFrameSession()
  }

  func startMonitoring() async throws {
    let requestID = nextRequestID
    nextRequestID += 1
    try await commandSender.send(
      .start,
      to: printer,
      requestID: requestID
    )
  }

  func frame() async throws -> CameraFrame {
    var components = URLComponents()
    components.scheme = "http"
    components.host = printer.host
    components.port = 80
    components.path = "/server/files/camera/monitor.jpg"
    components.queryItems = [
      URLQueryItem(
        name: "timestamp",
        value: String(Int(Date().timeIntervalSince1970 * 1_000))
      )
    ]

    guard let url = components.url else {
      throw MonitorError.invalidAddress
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 10
    )
    request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
    request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")

    let frameTask: Task<(Data, URLResponse), Error>
    let frameRequestID: UUID

    if let activeFrameTask, let activeFrameRequestID {
      frameTask = activeFrameTask
      frameRequestID = activeFrameRequestID
    } else {
      let newTask = Task {
        try await frameSession.data(for: request)
      }
      let newRequestID = UUID()
      activeFrameTask = newTask
      activeFrameRequestID = newRequestID
      frameTask = newTask
      frameRequestID = newRequestID
    }

    defer {
      if activeFrameRequestID == frameRequestID {
        activeFrameTask = nil
        activeFrameRequestID = nil
      }
    }

    let (data, response) = try await frameTask.value
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      !data.isEmpty
    else {
      throw MonitorError.invalidResponse
    }

    let identity = [
      response.value(forHTTPHeaderField: "ETag") ?? "",
      response.value(forHTTPHeaderField: "Last-Modified") ?? "",
      String(data.count),
      String(data.hashValue),
    ].joined(separator: "|")

    return CameraFrame(data: data, identity: identity)
  }

  func recoverMonitoring() async throws {
    resetFrameSession()
    try await startMonitoring()
  }

  func stopMonitoring() async {
    activeFrameTask?.cancel()
    activeFrameTask = nil
    activeFrameRequestID = nil
    frameSession.invalidateAndCancel()

    let requestID = nextRequestID
    nextRequestID += 1
    try? await commandSender.send(
      .stop,
      to: printer,
      requestID: requestID
    )
  }

  private func resetFrameSession() {
    activeFrameTask?.cancel()
    activeFrameTask = nil
    activeFrameRequestID = nil
    frameSession.invalidateAndCancel()
    frameSession = Self.makeFrameSession()
  }

  private static func makeFrameSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.urlCache = nil
    return URLSession(configuration: configuration)
  }
}
