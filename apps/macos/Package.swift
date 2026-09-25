// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyHopMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "KeyHopMenu", targets: ["KeyHopMenu"])],
    targets: [.executableTarget(name: "KeyHopMenu")]
)
