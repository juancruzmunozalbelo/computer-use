// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "computer-use",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "computer-use", path: "Sources/ComputerUse")
    ]
)
