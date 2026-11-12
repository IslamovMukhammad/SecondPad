// swift-tools-version: 6.2
import PackageDescription

// Everything runs on the main actor unless it says otherwise: the app is a menu-bar item plus a
// few small services; network and file work is marked `nonisolated` and runs off the main thread.
let settings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "SecondPad",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "SecondPad",
            path: "Sources/SecondPad",
            swiftSettings: settings
        ),
        .testTarget(
            name: "SecondPadTests",
            dependencies: ["SecondPad"],
            path: "Tests/SecondPadTests",
            swiftSettings: settings
        ),
    ]
)
