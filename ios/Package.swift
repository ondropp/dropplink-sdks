// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dropplink",
    // macOS is only listed so `swift test` runs on a Mac without a simulator; the SDK targets iOS.
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [
        .library(name: "Dropplink", targets: ["Dropplink"]),
    ],
    targets: [
        .target(
            name: "Dropplink",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "DropplinkTests",
            dependencies: ["Dropplink"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
