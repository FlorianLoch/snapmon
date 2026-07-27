import XCTest

@testable import SnapmakerMonitor

@MainActor
final class AppearancePreferencesTests: XCTestCase {
  func testPersistsInspectorTranslucency() {
    let suiteName = "AppearancePreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let model = AppModel(defaults: defaults)
    XCTAssertFalse(model.isInspectorTranslucent)

    model.setInspectorTranslucent(true)

    XCTAssertTrue(model.isInspectorTranslucent)
    XCTAssertTrue(defaults.bool(forKey: "inspector_translucent"))

    let restoredModel = AppModel(defaults: defaults)
    XCTAssertTrue(restoredModel.isInspectorTranslucent)
  }
}
