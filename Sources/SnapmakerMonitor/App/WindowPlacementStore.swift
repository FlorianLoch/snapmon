import CoreGraphics
import Foundation

struct WindowScreenGeometry: Codable, Equatable {
  let name: String
  let visibleFrame: CGRect
}

struct WindowPlacement: Codable, Equatable {
  let frame: CGRect
  let screen: WindowScreenGeometry

  func restoredFrame(on availableScreens: [WindowScreenGeometry]) -> CGRect? {
    guard let targetScreen = targetScreen(in: availableScreens) else {
      return nil
    }

    let targetBounds = targetScreen.visibleFrame
    let width = min(frame.width, targetBounds.width)
    let height = min(frame.height, targetBounds.height)
    let horizontalOffset = frame.minX - screen.visibleFrame.minX
    let topOffset = screen.visibleFrame.maxY - frame.maxY

    let proposedOrigin = CGPoint(
      x: targetBounds.minX + horizontalOffset,
      y: targetBounds.maxY - topOffset - height
    )

    return CGRect(
      x: clamp(
        proposedOrigin.x,
        minimum: targetBounds.minX,
        maximum: targetBounds.maxX - width
      ),
      y: clamp(
        proposedOrigin.y,
        minimum: targetBounds.minY,
        maximum: targetBounds.maxY - height
      ),
      width: width,
      height: height
    )
  }

  private func targetScreen(
    in availableScreens: [WindowScreenGeometry]
  ) -> WindowScreenGeometry? {
    let namedScreens = availableScreens.filter { $0.name == screen.name }
    if let closestNamedScreen = namedScreens.min(by: {
      screenDistance($0.visibleFrame) < screenDistance($1.visibleFrame)
    }) {
      return closestNamedScreen
    }

    return availableScreens.max {
      intersectionArea(frame, $0.visibleFrame) < intersectionArea(frame, $1.visibleFrame)
    }
  }

  private func screenDistance(_ candidate: CGRect) -> CGFloat {
    abs(candidate.minX - screen.visibleFrame.minX)
      + abs(candidate.minY - screen.visibleFrame.minY)
      + abs(candidate.width - screen.visibleFrame.width)
      + abs(candidate.height - screen.visibleFrame.height)
  }

  private func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
    let intersection = first.intersection(second)
    guard !intersection.isNull else {
      return 0
    }

    return intersection.width * intersection.height
  }

  private func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    min(max(value, minimum), maximum)
  }
}

struct WindowPlacementStore {
  private static let defaultsKey = "main_window_placement"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> WindowPlacement? {
    guard let data = defaults.data(forKey: Self.defaultsKey) else {
      return nil
    }

    return try? JSONDecoder().decode(WindowPlacement.self, from: data)
  }

  func save(_ placement: WindowPlacement) {
    guard let data = try? JSONEncoder().encode(placement) else {
      return
    }

    defaults.set(data, forKey: Self.defaultsKey)
  }
}
