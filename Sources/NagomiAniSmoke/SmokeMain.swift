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
}

@main
struct SmokeMain {
    static func main() async {
        guard let path = CommandLine.arguments.dropFirst().first else {
            print("usage: NagomiAniSmoke <video-file>")
            exit(1)
        }

        let engine = MPVPlaybackEngine()
        let delegate = SmokeDelegate()
        engine.delegate = delegate

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

        if engine.isPlaying && engine.currentTime > 1 {
            print("SMOKE OK")
            exit(0)
        } else {
            print("SMOKE FAIL")
            exit(1)
        }
    }
}
