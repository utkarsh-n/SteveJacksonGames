// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CardCore", platforms: [.iOS(.v17), .macOS(.v14)], products: [.library(name: "CardCore", targets: ["CardCore"])], targets: [.target(name: "CardCore", path: "Sources/CardCore"), .testTarget(name: "CardCoreTests", dependencies: ["CardCore"], path: "Tests/CardCoreTests")])
