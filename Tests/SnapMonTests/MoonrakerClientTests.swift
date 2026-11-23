import Foundation
import XCTest

@testable import SnapMon

final class MoonrakerClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    MockURLProtocol.reset()
  }

  func testReadsFirmwareFromPrinterProductInfo() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = MoonrakerClient(
      printer: SavedPrinter(name: "U1", host: "192.168.1.42", serialNumber: "U1-123"),
      session: URLSession(configuration: configuration)
    )

    let version = try await client.firmwareVersion()

    XCTAssertEqual(version, "1.6.0")
    XCTAssertEqual(MockURLProtocol.recordedRequests().map { $0.url?.path }, ["/machine/system_info"])
  }

  func testLEDCommandWaitsForConfirmedReadback() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let printer = SavedPrinter(
      name: "U1",
      host: "192.168.1.42",
      serialNumber: "U1-123"
    )
    let client = MoonrakerClient(printer: printer, session: session)

    let confirmedState = try await client.setLED(on: false)

    XCTAssertFalse(confirmedState)
    let requests = MockURLProtocol.recordedRequests()
    XCTAssertEqual(
      requests.map { $0.url?.path },
      [
        "/printer/gcode/script",
        "/printer/objects/query",
      ])

    let body = try XCTUnwrap(MockURLProtocol.recordedBodies().first ?? nil)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: String]
    )
    XCTAssertEqual(json["script"], "SET_LED LED=cavity_led WHITE=0")

    let queryItems = URLComponents(
      url: try XCTUnwrap(requests.last?.url),
      resolvingAgainstBaseURL: false
    )?.queryItems
    XCTAssertEqual(
      queryItems?.first(where: { $0.name == "led cavity_led" })?.value,
      "color_data"
    )
  }

  func testSpeedModifierCommandWaitsForConfirmedReadback() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let printer = SavedPrinter(
      name: "U1",
      host: "192.168.1.42",
      serialNumber: "U1-123"
    )
    let client = MoonrakerClient(printer: printer, session: session)

    let confirmedModifier = try await client.setSpeedModifier(120)

    XCTAssertEqual(confirmedModifier, 120)
    let requests = MockURLProtocol.recordedRequests()
    XCTAssertEqual(
      requests.map { $0.url?.path },
      [
        "/printer/gcode/script",
        "/printer/objects/query",
      ])

    let body = try XCTUnwrap(MockURLProtocol.recordedBodies().first ?? nil)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: String]
    )
    XCTAssertEqual(json["script"], "M220 S120")

    let queryItems = URLComponents(
      url: try XCTUnwrap(requests.last?.url),
      resolvingAgainstBaseURL: false
    )?.queryItems
    XCTAssertEqual(
      queryItems?.first(where: { $0.name == "gcode_move" })?.value,
      "speed_factor"
    )
  }

  func testCurrentStatusRequestsContinuouslyChangingObjects() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let printer = SavedPrinter(
      name: "U1",
      host: "192.168.1.42",
      serialNumber: "U1-123"
    )
    let client = MoonrakerClient(printer: printer, session: session)

    let status = try await client.currentStatus()

    XCTAssertEqual(status["print_stats"]?["print_duration"]?.doubleValue, 123)
    XCTAssertEqual(status["heater_bed"]?["temperature"]?.doubleValue, 61)
    XCTAssertEqual(
      status["print_stats"]?.value(at: "info", "current_layer")?.intValue,
      17
    )

    let request = try XCTUnwrap(MockURLProtocol.recordedRequests().last)
    let queryItems = URLComponents(
      url: try XCTUnwrap(request.url),
      resolvingAgainstBaseURL: false
    )?.queryItems
    let names = Set(queryItems?.map(\.name) ?? [])

    XCTAssertTrue(
      names.isSuperset(of: [
        "print_stats",
        "display_status",
        "virtual_sdcard",
        "heater_bed",
        "toolhead",
        "extruder",
        "extruder1",
        "extruder2",
        "extruder3",
        "temperature_sensor cavity",
        "purifier",
        "gcode_move",
        "led cavity_led",
      ]))
    XCTAssertEqual(queryItems?.first { $0.name == "temperature_sensor cavity" }?.value, "temperature")
    let purifierFields = queryItems?.first { $0.name == "purifier" }?.value?.split(separator: ",")
    XCTAssertEqual(
      Set(purifierFields ?? []),
      ["power_detected", "mode", "exhaust_fan", "inner_fan", "inner_fan_rpm"]
    )
  }

  func testFanSpeedUsesPurifierControlAndConfirmsReadback() async throws {
    let client = makeMockClient()

    let speed = try await client.setFanSpeed(5, for: .exhaust)

    XCTAssertEqual(speed, 0.05)
    let requests = MockURLProtocol.recordedRequests()
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
    XCTAssertEqual(requests.map { $0.url?.path }, [
      "/printer/objects/query", "/printer/control/purifier", "/printer/objects/query",
    ])
    XCTAssertEqual(requests.first?.url?.query, "purifier=power_detected,mode,exhaust_fan")
    XCTAssertEqual(requests.last?.url?.query, "purifier=exhaust_fan")

    let body = try XCTUnwrap(MockURLProtocol.recordedBodies().dropFirst().first ?? nil)
    let json = try JSONDecoder().decode(JSONValue.self, from: body)
    XCTAssertEqual(json, .object([
      "fan": .string("exhaust"), "speed": .number(5), "skip_delay": .number(1),
    ]))
  }

  func testFanSpeedRechecksModeBeforeSendingCommand() async throws {
    let client = makeMockClient()
    MockURLProtocol.setPurifierMode(.internalCirculation)

    do {
      _ = try await client.setFanSpeed(25, for: .exhaust)
      XCTFail("Expected the current mode to block the exhaust fan command.")
    } catch MonitorError.server(let message) {
      XCTAssertTrue(message.contains("current mode"))
    }

    XCTAssertEqual(MockURLProtocol.recordedRequests().map(\.httpMethod), ["GET"])
  }

  private func makeMockClient() -> MoonrakerClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return MoonrakerClient(
      printer: SavedPrinter(name: "U1", host: "192.168.1.42", serialNumber: "U1-123"),
      session: URLSession(configuration: configuration)
    )
  }
}

private final class MockURLProtocol: URLProtocol {
  private static let lock = NSLock()
  private static var requests: [URLRequest] = []
  private static var bodies: [Data?] = []
  private static var purifierMode = VentilationMode.externalCirculation

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let body = request.httpBody ?? Self.read(request.httpBodyStream)

    Self.lock.lock()
    Self.requests.append(request)
    Self.bodies.append(body)
    let purifierMode = Self.purifierMode
    Self.lock.unlock()

    let json: String

    let queryItems = URLComponents(
      url: request.url!,
      resolvingAgainstBaseURL: false
    )?.queryItems

    if request.url?.path == "/printer/gcode/script" {
      json = #"{"result":"ok"}"#
    } else if request.url?.path == "/printer/control/purifier" {
      json = #"{"result":{"state":"success"}}"#
    } else if request.url?.path == "/machine/system_info" {
      json = #"{"result":{"system_info":{"product_info":{"firmware_version":"1.6.0"}}}}"#
    } else if queryItems?.contains(where: { $0.name == "print_stats" }) == true {
      json =
        """
        {
          "result": {
            "status": {
              "print_stats": {
                "state": "printing",
                "print_duration": 123,
                "info": {"current_layer": 17, "total_layer": 42}
              },
              "heater_bed": {"temperature": 61, "target": 65}
            }
          }
        }
        """
    } else if queryItems?.contains(where: { $0.name == "purifier" }) == true {
      json = """
        {"result":{"status":{"purifier":{
          "power_detected":true,"mode":\(purifierMode.rawValue),
          "exhaust_fan":{"speed":0.05},"inner_fan":{"speed":0.4}
        }}}}
        """
    } else if queryItems?.contains(where: { $0.name == "gcode_move" }) == true {
      json = #"{"result":{"status":{"gcode_move":{"speed_factor":1.2}}}}"#
    } else {
      json =
        #"{"result":{"status":{"led cavity_led":{"color_data":[[0,0,0,0]]}}}}"#
    }

    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(
      self,
      didReceive: response,
      cacheStoragePolicy: .notAllowed
    )
    client?.urlProtocol(self, didLoad: Data(json.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {
    lock.lock()
    requests = []
    bodies = []
    purifierMode = .externalCirculation
    lock.unlock()
  }

  static func setPurifierMode(_ mode: VentilationMode) {
    lock.lock()
    purifierMode = mode
    lock.unlock()
  }

  static func recordedRequests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  static func recordedBodies() -> [Data?] {
    lock.lock()
    defer { lock.unlock() }
    return bodies
  }

  private static func read(_ stream: InputStream?) -> Data? {
    guard let stream else {
      return nil
    }

    stream.open()
    defer { stream.close() }

    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)

    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)

      if count < 0 {
        return nil
      }

      if count == 0 {
        break
      }

      result.append(buffer, count: count)
    }

    return result
  }
}
