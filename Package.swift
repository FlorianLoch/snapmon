// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "SnapMon",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(
      name: "SnapMon",
      targets: ["SnapMon"]
    )
  ],
  targets: [
    .executableTarget(
      name: "SnapMon"
    ),
    .testTarget(
      name: "SnapMonTests",
      dependencies: ["SnapMon"]
    ),
  ],
  swiftLanguageVersions: [.v5]
)
