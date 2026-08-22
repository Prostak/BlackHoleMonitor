// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SerialKeyboardBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SerialKeyboardBridge",
            path: "Sources/SerialKeyboardBridge"
        ),
    ]
)
