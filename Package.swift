// swift-tools-version: 5.9
import PackageDescription
import Foundation

// onnxruntime: the official macOS arm64 build (C API), fetched by scripts/fetch_ort.sh into vendor/onnxruntime.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ort = "\(root)/vendor/onnxruntime"

let package = Package(
    name: "Keylime",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Keylime", targets: ["AutocorrectApp"]),
        .library(name: "AutocorrectEngine", targets: ["Engine"]),
    ],
    targets: [
        .target(
            name: "COrt",
            path: "Sources/COrt",
            cSettings: [.unsafeFlags(["-I\(ort)/include"])],
            linkerSettings: [.unsafeFlags([
                "-L\(ort)/lib", "-lonnxruntime",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "\(ort)/lib",
            ])]
        ),
        .target(name: "Engine", dependencies: ["COrt"], path: "Sources/Engine"),
        .target(name: "KeylimeCore", dependencies: ["Engine"], path: "Sources/KeylimeCore"),
        .executableTarget(
            name: "AutocorrectApp",
            dependencies: ["Engine", "KeylimeCore"],
            path: "Sources/AutocorrectApp",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"), .linkedFramework("ApplicationServices")]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine", "KeylimeCore"],
            path: "Tests/EngineTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CoreTests", dependencies: ["KeylimeCore"], path: "Tests/CoreTests"),
    ]
)
