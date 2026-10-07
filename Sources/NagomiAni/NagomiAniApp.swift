import SwiftUI

@main
struct NagomiAniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("NagomiAni") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            // 应用菜单「检查更新…」（开发模式内部静默跳过）
            CommandGroup(after: .newItem) {
                Button("检查更新…") {
                    Task { await UpdateCenter.shared.check() }
                }
                .keyboardShortcut("u", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以普通应用方式激活（从命令行 swift run 启动时也能获得焦点）
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 构建标识：终端运行 swift run NagomiAni 时可见，用于确认跑的是最新构建
        print("[NagomiAni] 启动 ✓ 构建标识 release-1.0.0")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
