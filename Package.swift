// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Omnia",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Omnia", targets: ["Omnia"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.1")
    ],
    targets: [
        .executableTarget(
            name: "Omnia",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KeychainAccess", package: "KeychainAccess")
            ],
            path: "Omnia",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "OmniaTests",
            dependencies: ["Omnia"],
            path: "Tests/OmniaTests"
        )
    ]
)
