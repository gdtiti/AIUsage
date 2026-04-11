// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuotaBackend",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuotaBackend", targets: ["QuotaBackend"]),
        .executable(name: "QuotaServer", targets: ["QuotaServer"])
    ],
    targets: [
        .target(
            name: "QuotaBackend",
            path: "Sources/QuotaBackend"
        ),
        .executableTarget(
            name: "QuotaServer",
            dependencies: ["QuotaBackend"],
            path: "Sources/QuotaServer"
        ),
        .testTarget(
            name: "QuotaBackendTests",
            dependencies: ["QuotaBackend"],
            path: "Tests/QuotaBackendTests"
        )
    ]
)
