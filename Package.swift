// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PrimeSnap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PrimeSnap",
            path: "Sources/PrimeSnap",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
