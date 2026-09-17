// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaydayCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "PaydayCore",
            targets: ["PaydayCore"]
        )
    ],
    targets: [
        .target(
            name: "PaydayCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "PaydayCoreTests",
            dependencies: ["PaydayCore"],
            // Fixtures/*.json are shared with the Deno golden test; the
            // directory is copied whole so Bundle.module can list it.
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
