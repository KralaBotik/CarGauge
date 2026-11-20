// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CarGauge",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "CarGaugeCore", targets: ["CarGaugeCore"]),
        .executable(name: "cargauge-simulator", targets: ["CarGaugeSimulator"])
    ],
    targets: [
        .target(name: "CarGaugeCore"),
        .executableTarget(name: "CarGaugeSimulator", dependencies: ["CarGaugeCore"]),
        .testTarget(name: "CarGaugeCoreTests", dependencies: ["CarGaugeCore"])
    ]
)
