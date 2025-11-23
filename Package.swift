// swift-tools-version: 6.2.1

import PackageDescription

let package = Package(
    name: "Launchy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "launchy",
            targets: ["Launchy"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Launchy",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "App",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                // Ensure bundled frameworks like Sparkle are found at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"], .when(platforms: [.macOS]))
            ]
        )
    ]
)
