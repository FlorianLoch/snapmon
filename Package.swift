// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "SnapmakerMonitor",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "SnapmakerMonitor",
      targets: ["SnapmakerMonitor"]
    )
  ],
  targets: [
    .executableTarget(
      name: "SnapmakerMonitor"
    ),
    .testTarget(
      name: "SnapmakerMonitorTests",
      dependencies: ["SnapmakerMonitor"]
    ),
  ],
  swiftLanguageVersions: [.v5]
)
