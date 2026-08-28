// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Vendor 目录下的 libmpv（来自 IINA 的 GPL 构建，含全部依赖闭包）
let vendorLibDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Vendor/libmpv")
    .path

let package = Package(
    name: "NagomiAni",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "Cmpv",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NagomiAniCore",
            dependencies: ["Cmpv"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", vendorLibDir,
                    "-lmpv",
                    "-Xlinker", "-rpath", "-Xlinker", vendorLibDir,
                ])
            ]
        ),
        .executableTarget(
            name: "NagomiAni",
            dependencies: ["NagomiAniCore"]
        ),
        // 无界面冒烟测试：swift run NagomiAniSmoke <视频文件>
        .executableTarget(
            name: "NagomiAniSmoke",
            dependencies: ["NagomiAniCore"]
        ),
        .testTarget(
            name: "NagomiAniCoreTests",
            dependencies: ["NagomiAniCore"]
        ),
    ]
)
