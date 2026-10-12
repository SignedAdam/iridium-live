// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MeetingKit", type: .static, targets: ["MeetingKit"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.14.7")],
    targets: [
        .target(
            name: "MeetingKit",
            dependencies: ["FluidAudio"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
