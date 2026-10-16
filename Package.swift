// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aux",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Aux", targets: ["Aux"])],
    targets: [
        .target(name: "AuxCore"),
        .executableTarget(name: "Aux", dependencies: ["AuxCore"]),
        .testTarget(name: "AuxCoreTests", dependencies: ["AuxCore"])
    ],
    swiftLanguageModes: [.v5]
)
