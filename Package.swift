// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Bubbleg",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Bubbleg", path: "Sources/Bubbleg"),
    ]
)
