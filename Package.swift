// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SuijiCore",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "SuijiCore", targets: ["SuijiCore"])],
    targets: [
        .target(name: "SuijiCore"),
        .testTarget(name: "SuijiCoreTests", dependencies: ["SuijiCore"])
    ],
    swiftLanguageModes: [.v5]
)
