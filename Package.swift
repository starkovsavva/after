// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Posle",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Posle", targets: ["PosleApp"])],
    targets: [
        .target(name: "PosleCore"),
        .executableTarget(name: "PosleApp", dependencies: ["PosleCore"])
    ]
)
