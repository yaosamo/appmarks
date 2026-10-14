// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SideStage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SideStage", path: "Sources/SideStage"),
    ]
)
