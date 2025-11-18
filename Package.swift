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
    targets: [
        .executableTarget(
            name: "Launchy",
            path: "App",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
