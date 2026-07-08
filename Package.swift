// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIBar", targets: ["AIBar"])
    ],
    targets: [
        .executableTarget(
            name: "AIBar",
            path: "Sources/AIBar"
        )
    ]
)
