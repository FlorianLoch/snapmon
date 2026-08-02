import XCTest

@testable import SnapMon

final class WindowPersistenceTests: XCTestCase {
  func testRoundTripsPlacementThroughAppOwnedDefaults() {
    let suiteName = "WindowPersistenceTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Could not create isolated defaults")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let placement = WindowPlacement(
      frame: CGRect(x: -1_300, y: 220, width: 1_100, height: 700),
      screen: WindowScreenGeometry(
        name: "External Display",
        visibleFrame: CGRect(x: -1_800, y: 0, width: 1_800, height: 1_130)
      )
    )
    let store = WindowPlacementStore(defaults: defaults)

    store.save(placement)

    XCTAssertEqual(store.load(), placement)
  }

  func testRestoresSizeAndRelativePositionOnTheSameDisplay() {
    let placement = WindowPlacement(
      frame: CGRect(x: 100, y: 300, width: 800, height: 600),
      screen: WindowScreenGeometry(
        name: "External Display",
        visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
      )
    )
    let movedDisplay = WindowScreenGeometry(
      name: "External Display",
      visibleFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
    )

    let restoredFrame = placement.restoredFrame(on: [movedDisplay])

    XCTAssertEqual(
      restoredFrame,
      CGRect(x: -1_340, y: 120, width: 800, height: 600)
    )
  }

  func testConstrainsPlacementToTheAvailableDisplay() {
    let placement = WindowPlacement(
      frame: CGRect(x: 1_700, y: 900, width: 1_600, height: 1_000),
      screen: WindowScreenGeometry(
        name: "Disconnected Display",
        visibleFrame: CGRect(x: 0, y: 0, width: 3_200, height: 1_800)
      )
    )
    let availableDisplay = WindowScreenGeometry(
      name: "Built-in Display",
      visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    let restoredFrame = placement.restoredFrame(on: [availableDisplay])

    XCTAssertEqual(
      restoredFrame,
      CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )
  }
}
