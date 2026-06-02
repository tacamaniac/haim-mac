// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HermesMac",
            path: "Sources/HermesMac",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
