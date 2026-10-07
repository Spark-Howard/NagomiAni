import AppKit
import Foundation

/// 播放选项
public struct PlaybackOptions: Sendable {
    public var startTime: Double
    public var autoplay: Bool
    /// 附加 HTTP 请求头（在线流用，如 Referer/Cookie；本地文件忽略）
    public var httpHeaders: [String: String]
    /// 覆盖 User-Agent（nil 不设置）
    public var userAgent: String?

    public init(
        startTime: Double = 0,
        autoplay: Bool = true,
        httpHeaders: [String: String] = [:],
        userAgent: String? = nil
    ) {
        self.startTime = startTime
        self.autoplay = autoplay
        self.httpHeaders = httpHeaders
        self.userAgent = userAgent
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
    /// 是否为外挂轨道（mpv 中 external=yes，如外挂字幕文件）
    public let isExternal: Bool
    /// 外挂文件的路径（存在时可用于显示文件名）
    public let externalFilename: String?

    public init(
        id: Int,
        kind: MediaKind,
        name: String?,
        language: String?,
        isSelected: Bool,
        isExternal: Bool = false,
        externalFilename: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.language = language
        self.isSelected = isSelected
        self.isExternal = isExternal
        self.externalFilename = externalFilename
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
    /// 轨道列表变化（内置轨道就绪、外挂字幕加载、轨道选择变更等）
    func playbackEngineDidUpdateTracks(_ engine: PlaybackEngine)
    /// 时长已知或变化（秒）。不能只在 ready 状态读一次 duration：
    /// ready 可能早于时长属性事件送达（竞态读出 0），且"加载期被暂停"路径
    /// 状态直接进 paused 不经过 ready——UI 依赖该回调修正进度条量程
    func playbackEngine(_ engine: PlaybackEngine, didUpdateDuration duration: Double)
}

public extension PlaybackEngineDelegate {
    func playbackEngineDidUpdateTracks(_ engine: PlaybackEngine) {}
    func playbackEngine(_ engine: PlaybackEngine, didUpdateDuration duration: Double) {}
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

    /// 挂载外部字幕文件（.srt/.ass/.vtt 等），成功返回 true
    func addExternalSubtitle(url: URL) -> Bool
    /// 开关字幕显示（false = 关闭）
    func setSubtitleEnabled(_ enabled: Bool)

    /// 引擎提供的视频渲染视图（UI 层直接嵌入）
    var videoSurface: NSView? { get }

    static var capabilities: PlaybackCapabilities { get }
}

public extension PlaybackEngine {
    /// 默认实现：不支持外挂字幕的内核直接返回 false
    func addExternalSubtitle(url: URL) -> Bool { false }
    /// 默认实现：无操作
    func setSubtitleEnabled(_ enabled: Bool) {}
}
