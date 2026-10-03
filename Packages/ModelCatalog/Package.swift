// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModelCatalog",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "OpenRouterCatalog", targets: ["OpenRouterCatalog"]),
        .library(name: "SortableTable", targets: ["SortableTable"]),
    ],
    targets: [
        .target(name: "OpenRouterCatalog", resources: [.copy("../../Brands")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "SortableTable", swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
