// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProbeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ProbeCore", targets: ["ProbeCore"]),
        .executable(name: "ProbeFixtureGenerator", targets: ["ProbeFixtureGenerator"])
    ],
    targets: [
        .target(name: "ProbeCore"),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
        .executableTarget(name: "ProbeFixtureGenerator", dependencies: ["ProbeCore"])
    ]
)
