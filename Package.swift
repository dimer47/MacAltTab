// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MacAltTab",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "MacAltTab", path: "Sources/MacAltTab",
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
