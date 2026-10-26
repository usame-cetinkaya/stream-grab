// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StreamGrab",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StreamGrab",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
    ],
    swiftLanguageModes: [.v5]
)
