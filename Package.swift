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
        // ⚠️ 必须是 26.0+：Liquid Glass（含 macOS 26/27 的原生三色按钮新外观）
        // 是「按链接 SDK 版本」整体启用的，二进制里 LC_BUILD_VERSION 的 sdk 低于
        // 26.0 时系统会退回旧的 Tahoe 外观 —— 标题栏 28pt、按钮 14×16；
        // 26.0+ 才拿到新外观：标题栏 32pt、按钮 14×14 圆形玻璃。
        // 实测阈值：13.0/15.0 = 旧外观，26.0/27.0 = 新外观。
        .macOS("26.0")
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
