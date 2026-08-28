import AppKit
import Foundation

/// 播放选项
public struct PlaybackOptions: Sendable {
    public var startTime: Double
    public var autoplay: Bool

    public init(startTime: Double = 0, autoplay: Bool = true) {
        self.startTime = startTime
        self.autoplay = autoplay
    }
}

/// 播放状态
public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case finished
    case failed(String)
}

/// 媒体轨道（音频 / 字幕）
public struct MediaTrack: Identifiable, Equatable, Sendable {
    public enum MediaKind: Sendable {
        case video, audio, subtitle
    }

    public let id: Int
    public let kind: MediaKind
    public let name: String?
    public let language: String?
    public let isSelected: Bool

    public init(id: Int, kind: MediaKind, name: String?, language: String?, isSelected: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.language = language
        self.isSelected = isSelected
    }
}

/// 播放器能力声明（供 UI 判断是否显示轨道切换等）
public struct PlaybackCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let audioTrackSelection = PlaybackCapabilities(rawValue: 1 << 0)
    public static let subtitleTrackSelection = PlaybackCapabilities(rawValue: 1 << 1)
    public static let accurateSeek = PlaybackCapabilities(rawValue: 1 << 2)
}

/// 播放错误
public enum PlaybackError: LocalizedError {
    case notPlayable
    case unknown

    public var errorDescription: String? {
        switch self {
        case .notPlayable: return "文件无法播放"
        case .unknown: return "未知播放错误"
        }
    }
}

/// 引擎事件回调（在主线程调用）
public protocol PlaybackEngineDelegate: AnyObject {
    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double)
    func playbackEngine(_ engine: PlaybackEngine, didChangeState state: PlaybackState)
    func playbackEngineDidFinish(_ engine: PlaybackEngine)
    func playbackEngine(_ engine: PlaybackEngine, didFailWith error: Error)
}

/// 播放内核抽象：UI 与业务逻辑只依赖此协议，不关心底层实现
public protocol PlaybackEngine: AnyObject {
    var delegate: PlaybackEngineDelegate? { get set }

    /// 加载并准备播放
    func load(url: URL, options: PlaybackOptions) async throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double, completion: ((Bool) -> Void)?)

    /// 状态
    var duration: Double { get }
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    var rate: Float { get set }

    /// 轨道
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    /// index 为轨道数组下标；-1 表示关闭
    func selectAudioTrack(_ index: Int)
    func selectSubtitleTrack(_ index: Int)

    /// 引擎提供的视频渲染视图（UI 层直接嵌入）
    var videoSurface: NSView? { get }

    static var capabilities: PlaybackCapabilities { get }
}
