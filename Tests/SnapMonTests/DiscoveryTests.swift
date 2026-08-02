import XCTest

@testable import SnapMon

final class DiscoveryTests: XCTestCase {
  func testAcceptsOnlyU1InLANMode() {
    let device = DiscoveredDevice.fromBonjour(
      serviceName: "Workshop",
      txt: [
        "machine_type": "Snapmaker U1",
        "link_mode": "lan",
        "device_name": "Workshop U1",
        "sn": "U1-123",
        "ip": "192.168.1.42",
        "version": "1.5.0",
      ]
    )

    XCTAssertEqual(device?.id, "U1-123")
    XCTAssertEqual(device?.name, "Workshop U1")
    XCTAssertEqual(device?.host, "192.168.1.42")
    XCTAssertEqual(device?.firmwareVersion, "1.5.0")
  }

  func testRejectsWANMode() {
    let device = DiscoveredDevice.fromBonjour(
      serviceName: "Workshop",
      txt: [
        "machine_type": "Snapmaker U1",
        "link_mode": "wan",
        "ip": "192.168.1.42",
      ]
    )

    XCTAssertNil(device)
  }

  func testRejectsAnotherModel() {
    let device = DiscoveredDevice.fromBonjour(
      serviceName: "Artisan",
      txt: [
        "machine_type": "Snapmaker Artisan",
        "link_mode": "lan",
        "ip": "192.168.1.42",
      ]
    )

    XCTAssertNil(device)
  }

  func testFallbackServiceNameMatchesPersistedPrinter() {
    let device = DiscoveredDevice.fromBonjour(
      serviceName: "Workshop-U1",
      txt: [
        "machine_type": "Snapmaker U1",
        "link_mode": "lan",
        "ip": "192.168.1.42",
      ]
    )

    guard let device else {
      XCTFail("Expected the fallback device to be accepted")
      return
    }

    XCTAssertEqual(device.id, "Workshop-U1")
    XCTAssertEqual(device.savedPrinter.serialNumber, "Workshop-U1")
    XCTAssertTrue(device.matches(device.savedPrinter))
  }
}
