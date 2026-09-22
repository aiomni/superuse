// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "superuse",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "superuse", targets: ["Suse"])],
    targets: [
        .target(name: "SuseCore"),
        .executableTarget(name: "Suse", dependencies: ["SuseCore"]),
        .testTarget(name: "SuseCoreTests", dependencies: ["SuseCore"]),
        .testTarget(name: "SuseAppTests", dependencies: ["Suse", "SuseCore"]),
    ]
)
