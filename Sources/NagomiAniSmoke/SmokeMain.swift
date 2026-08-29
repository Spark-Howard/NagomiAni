import AppKit
import Foundation
import NagomiAniCore

/// 冒烟测试工具：无界面加载并播放一个视频文件，验证 mpv 内核不崩溃
/// 用法：swift run NagomiAniSmoke <视频文件路径>

final class SmokeDelegate: PlaybackEngineDelegate {
    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double) {}
    func playbackEngine(_ engine: PlaybackEngine, didChangeState state: PlaybackState) {
        print("  state: \(state)")
    }
    func playbackEngineDidFinish(_ engine: PlaybackEngine) {
        print("  finished")
    }
    func playbackEngine(_ engine: PlaybackEngine, didFailWith error: Error) {
        print("  error: \(error)")
    }
    func playbackEngineDidUpdateTracks(_ engine: PlaybackEngine) {
        print("  tracks: audio=\(engine.audioTracks.count) sub=\(engine.subtitleTracks.count)")
    }
}

@main
struct SmokeMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let path = args.first, !path.hasPrefix("--") else {
            print("usage: NagomiAniSmoke <video-file> [--sub subtitle-file] [--switch video2] [--window]")
            exit(1)
        }
        let subtitlePath = args.optionValue(after: "--sub")
        let switchPath = args.optionValue(after: "--switch")
        let windowMode = args.contains("--window")

        let engine = MPVPlaybackEngine()
        let delegate = SmokeDelegate()
        engine.delegate = delegate

        // 窗口模式：模拟 GUI 的视图挂载/移除/重加（对应切页时 PlayerView 销毁重建）
        var window: NSWindow?
        if windowMode {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            if let view = engine.videoSurface {
                view.frame = win.contentView!.bounds
                view.autoresizingMask = [.width, .height]
                win.contentView?.addSubview(view)
            }
            win.makeKeyAndOrderFront(nil)
            window = win
            print("[win] window created, view attached")
            await wait(1_000_000_000)
        }

        print("loading: \(path)")
        do {
            try await engine.load(url: URL(fileURLWithPath: path), options: PlaybackOptions(autoplay: true))
        } catch {
            print("load failed: \(error)")
            exit(1)
        }

        func wait(_ ns: UInt64) async { try? await Task.sleep(nanoseconds: ns) }

        // 播放/暂停循环：验证状态机（曾经第二次暂停后失效的 bug）
        await wait(1_500_000_000)
        print("[1] playing: isPlaying=\(engine.isPlaying)")

        engine.pause()
        await wait(500_000_000)
        print("[2] after pause: isPlaying=\(engine.isPlaying)")

        engine.play()
        await wait(500_000_000)
        print("[3] after resume: isPlaying=\(engine.isPlaying)")

        engine.pause()
        await wait(500_000_000)
        print("[4] after 2nd pause: isPlaying=\(engine.isPlaying)")

        engine.play()
        await wait(1_000_000_000)
        print("[5] after 2nd resume: isPlaying=\(engine.isPlaying) time=\(engine.currentTime)")

        // 外挂字幕挂载：验证 sub-add、轨道列表、开关与延迟
        if let subtitlePath {
            let subURL = URL(fileURLWithPath: subtitlePath)
            let added = engine.addExternalSubtitle(url: subURL)
            print("[6] addExternalSubtitle: added=\(added)")
            await wait(300_000_000)
            let external = engine.subtitleTracks.filter { $0.isExternal }
            print("[7] external subtracks: \(external.map { $0.name ?? "?" })")
            if !added || external.isEmpty {
                print("SMOKE FAIL (subtitle)")
                exit(1)
            }
            engine.setSubtitleEnabled(false)
            await wait(200_000_000)
            print("[8] after disable: selected=\(engine.subtitleTracks.filter { $0.isSelected }.count)")
            engine.setSubtitleEnabled(true)
            engine.subtitleDelay = 1.5
            print("[9] subtitleDelay=\(engine.subtitleDelay)")
            if engine.subtitleTracks.contains(where: { $0.isSelected }) && engine.subtitleDelay == 1.5 {
                print("SMOKE OK (subtitle)")
            } else {
                print("SMOKE FAIL (subtitle)")
                exit(1)
            }
        }

        // 播放中切换视频（replace）：验证旧文件 END_FILE(stop) 不被误判为加载失败
        if let switchPath {
            // 窗口模式下先模拟"切到番库页"：移除视频视图（PlayerView 销毁）
            if let win = window, let view = engine.videoSurface {
                print("[win] removing view (simulate switching page)")
                view.removeFromSuperview()
                win.orderOut(nil)
                await wait(1_000_000_000)
            }

            print("[10] switching to: \(switchPath)")
            do {
                try await engine.load(url: URL(fileURLWithPath: switchPath), options: PlaybackOptions(autoplay: true))
            } catch {
                print("switch failed: \(error)")
                print("SMOKE FAIL (switch)")
                exit(1)
            }

            // 窗口模式下再模拟"切回播放器页"：重新挂载视频视图
            if let win = window, let view = engine.videoSurface {
                view.frame = win.contentView!.bounds
                view.autoresizingMask = [.width, .height]
                win.contentView?.addSubview(view)
                win.makeKeyAndOrderFront(nil)
                print("[win] view re-attached")
            }

            await wait(1_500_000_000)
            print("[11] after switch: state=\(engine.state) isPlaying=\(engine.isPlaying) time=\(engine.currentTime)")
            if engine.isPlaying && engine.currentTime > 0.5 {
                print("SMOKE OK")
                exit(0)
            } else {
                print("SMOKE FAIL (switch)")
                exit(1)
            }
        }

        if engine.isPlaying && engine.currentTime > 1 {
            print("SMOKE OK")
            exit(0)
        } else {
            print("SMOKE FAIL")
            exit(1)
        }
    }
}

private extension Array where Element == String {
    /// 取 --flag 后的下一个参数值
    func optionValue(after flag: String) -> String? {
        guard let idx = firstIndex(of: flag), indices.contains(idx + 1) else { return nil }
        return self[idx + 1]
    }
}
