import AppKit
import Foundation
import NagomiAniCore

/// 播放器的 UI 状态模型：桥接 PlaybackEngine 与 SwiftUI
final class PlayerModel: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var fileName: String?
    @Published var isSeeking = false
    @Published var seekValue: Double = 0

    let engine = MPVPlaybackEngine()

    init() {
        engine.delegate = self
    }

    // MARK: - 动作

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择一个视频文件"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await load(url: url) }
        }
    }

    func load(url: URL) async {
        fileName = url.lastPathComponent
        do {
            try await engine.load(url: url, options: PlaybackOptions())
        } catch {
            // 引擎已通过 delegate 上报 failed 状态
        }
    }

    func togglePlayPause() {
        if engine.isPlaying {
            engine.pause()
        } else {
            if state == .finished {
                engine.seek(to: 0, completion: nil)
            }
            engine.play()
        }
    }

    func seek(to seconds: Double) {
        engine.seek(to: seconds, completion: nil)
    }

    // MARK: - 派生状态

    var isLoading: Bool { state == .loading }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var formattedCurrentTime: String { Self.format(currentTime) }
    var formattedDuration: String { Self.format(duration) }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - PlaybackEngineDelegate

extension PlayerModel: PlaybackEngineDelegate {
    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double) {
        if !isSeeking { currentTime = time }
    }

    func playbackEngine(_ engine: PlaybackEngine, didChangeState state: PlaybackState) {
        self.state = state
        if case .ready = state {
            duration = engine.duration
        }
    }

    func playbackEngineDidFinish(_ engine: PlaybackEngine) {}

    func playbackEngine(_ engine: PlaybackEngine, didFailWith error: Error) {}
}
