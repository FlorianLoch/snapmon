import XCTest

@testable import SnapmakerMonitor

final class JSONValueTests: XCTestCase {
  func testDecodesMoonrakerShape() throws {
    let data = Data(
      """
      {
        "result": {
          "status": {
            "print_stats": {
              "state": "printing",
              "print_duration": 42.5
            }
          }
        }
      }
      """.utf8
    )

    let value = try JSONDecoder().decode(JSONValue.self, from: data)

    XCTAssertEqual(
      value.value(
        at: "result",
        "status",
        "print_stats",
        "state"
      )?.stringValue,
      "printing"
    )
    XCTAssertEqual(
      value.value(
        at: "result",
        "status",
        "print_stats",
        "print_duration"
      )?.doubleValue,
      42.5
    )
  }
}
