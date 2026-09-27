// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyFanControl",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SMCKit"),
        .executableTarget(name: "smcprobe", dependencies: ["SMCKit"]),
        .executableTarget(name: "fanctld", dependencies: ["SMCKit"]),
        .executableTarget(name: "MyFanControl", dependencies: ["SMCKit"]),
    ]
)
