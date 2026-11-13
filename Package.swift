// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "LiteMux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiteMux", targets: ["LiteMux"]),
        .library(name: "LiteMuxCore", targets: ["LiteMuxCore"]),
    ],
    dependencies: [
        // Pure-Swift terminal engine with a Metal renderer (MIT).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3"),
    ],
    targets: [
        // Foundation-only logic: ssh config, command parsing, SFTP, probes, layout.
        .target(
            name: "LiteMuxCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "LiteMux",
            dependencies: [
                "LiteMuxCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "LiteMuxCoreTests",
            dependencies: ["LiteMuxCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
