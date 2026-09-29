// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "Scan", platforms: [.macOS(.v14)],
    products: [.executable(name: "Scan", targets: ["ScanApp"]), .executable(name: "scan-cli", targets: ["scan-cli"]), .library(name: "ScanEngine", targets: ["ScanEngine"]), .library(name: "ScanGrid", targets: ["ScanGrid"]), .library(name: "ScanQuery", targets: ["ScanQuery"]), .library(name: "ScanTheme", targets: ["ScanTheme"]), .executable(name: "ScanBench", targets: ["ScanBench"])],
    targets: [
        .target(name: "CDuckDB", publicHeadersPath: "include", linkerSettings: [.unsafeFlags(["-L" + root + "/Vendor/DuckDB", "-lduckdb_shared", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks", "-Xlinker", "-rpath", "-Xlinker", root + "/Vendor/DuckDB"]), .linkedLibrary("c++")]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "ScanQuery"), .target(name: "ScanEngine", dependencies: ["CDuckDB", "CSQLite", "ScanQuery"]),
        .target(name: "ScanTheme", dependencies: ["ScanQuery"]),
        .target(name: "ScanGrid", dependencies: ["ScanQuery", "ScanTheme"]),
        .executableTarget(name: "ScanApp", dependencies: ["ScanEngine", "ScanGrid", "ScanTheme", "ScanQuery"], path: "App", exclude: ["Info.plist", "Scan.entitlements", "AppIcon.icns", "Assets.xcassets"]),
        .executableTarget(name: "scan-cli"), .executableTarget(name: "ScanBench", dependencies: ["ScanEngine", "ScanQuery"], path: "bench/ScanBench"),
        .testTarget(name: "ScanQueryTests", dependencies: ["ScanQuery", "ScanTheme"]),
        .testTarget(name: "ScanEngineTests", dependencies: ["ScanEngine", "ScanQuery"]),
        .testTarget(name: "ScanPerfTests", dependencies: ["ScanEngine"])
    ])
