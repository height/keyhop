// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyHopMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "KeyHopMenu", targets: ["KeyHopMenu"])],
    targets: [
        .target(name: "KeyHopCore"),
        .executableTarget(name: "KeyHopMenu", dependencies: ["KeyHopCore"]),
        .testTarget(name: "KeyHopCoreTests", dependencies: ["KeyHopCore"])
    ]
)
