// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aplyna",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Aplyna", targets: ["Aplyna"])],
    targets: [
        .target(name: "Aplyna", path: "ios/Sources/Aplyna"),
        .testTarget(name: "AplynaTests", dependencies: ["Aplyna"], path: "ios/Tests/AplynaTests"),
    ]
)
