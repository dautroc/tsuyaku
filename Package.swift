// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tsuyaku",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Tsuyaku",
            path: "Sources/Tsuyaku",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        )
    ]
)
