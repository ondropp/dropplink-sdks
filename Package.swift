// swift-tools-version:5.9
import PackageDescription

// The manifest SwiftPM resolves for `.package(url: "https://github.com/ondropp/dropplink-sdks.git", ...)`:
// remote packages are read from the repository root, so this points at ios/. Tests and local work use
// ios/Package.swift (docs/releasing.md).
let package = Package(
    name: "Dropplink",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "Dropplink", targets: ["Dropplink"]),
    ],
    targets: [
        .target(
            name: "Dropplink",
            path: "ios/Sources/Dropplink",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
