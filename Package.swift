// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIUsageMenuBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AIUsageMenuBar", targets: ["AIUsageMenuBar"])
    ],
    targets: [
        .executableTarget(
            name: "AIUsageMenuBar",
            path: "Sources/AIUsageMenuBar"
        )
    ]
)
