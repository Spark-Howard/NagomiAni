import AVFoundation
import AVKit
import Foundation

/// 基于 AVPlayer 的播放内核（阶段一实现）
public final class AVPlaybackEngine: NSObject, PlaybackEngine {
    public static var capabilities: PlaybackCapabilities = [
        .audioTrackSelection, .subtitleTrackSelection, .accurateSeek
    ]

    public weak var delegate: PlaybackEngineDelegate?

    public private(set) var state: PlaybackState = .idle {
        didSet { delegate?.playbackEngine(self, didChangeState: state) }
    }

    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var loadedDuration: Double = 0
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?

    /// 供视频渲染层使用（AVPlayerView）
    public var underlyingPlayer: AVPlayer { player }

    public var videoSurface: NSView? { playerView }
    private lazy var playerView: AVPlayerView = {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }()

    public override init() {
        super.init()
        // 播放/暂停/缓冲状态自动同步
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard let self else { return }
            switch player.timeControlStatus {
            case .playing:
                self.state = .playing
            case .paused:
                if self.state != .finished { self.state = .paused }
            default:
                break
            }
        }
    }

    deinit {
        removeTimeObserver()
        timeControlObservation?.invalidate()
        removeItemObservers()
    }

    // MARK: - PlaybackEngine

    public var duration: Double { loadedDuration }

    public var currentTime: Double {
        let time = player.currentTime()
        return time.isNumeric ? time.seconds : 0
    }

    public var isPlaying: Bool { player.timeControlStatus == .playing }

    public var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }

    public func load(url: URL, options: PlaybackOptions) async throws {
        stop()

        state = .loading
        let newItem = AVPlayerItem(url: url)
        item = newItem
        player.replaceCurrentItem(with: newItem)

        do {
            let isPlayable = try await newItem.asset.load(.isPlayable)
            guard isPlayable else {
                state = .failed(PlaybackError.notPlayable.localizedDescription)
                throw PlaybackError.notPlayable
            }
            let duration = try await newItem.asset.load(.duration)
            loadedDuration = duration.isNumeric ? duration.seconds : 0
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }

        await refreshMediaSelectionGroups()
        installItemObservers()

        if options.startTime > 0 {
            seek(to: options.startTime, completion: nil)
        }

        state = .ready
        if options.autoplay {
            play()
        }
    }

    public func play() {
        if case .failed = state { return }
        player.play()
    }

    public func pause() {
        player.pause()
    }

    public func stop() {
        removeItemObservers()
        removeTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        audibleGroup = nil
        legibleGroup = nil
        loadedDuration = 0
        state = .idle
    }

    public func seek(to seconds: Double, completion: ((Bool) -> Void)?) {
        guard seconds.isFinite else {
            completion?(false)
            return
        }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            completion?(finished)
        }
    }

    public var audioTracks: [MediaTrack] {
        tracks(from: audibleGroup, kind: .audio)
    }

    public var subtitleTracks: [MediaTrack] {
        tracks(from: legibleGroup, kind: .subtitle)
    }

    public func selectAudioTrack(_ index: Int) {
        selectOption(at: index, in: audibleGroup)
    }

    public func selectSubtitleTrack(_ index: Int) {
        selectOption(at: index, in: legibleGroup)
    }

    // MARK: - Private

    private func tracks(from group: AVMediaSelectionGroup?, kind: MediaTrack.MediaKind) -> [MediaTrack] {
        guard let group else { return [] }
        let selected = player.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            MediaTrack(
                id: index,
                kind: kind,
                name: option.displayName,
                language: option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier,
                isSelected: option == selected
            )
        }
    }

    private func selectOption(at index: Int, in group: AVMediaSelectionGroup?) {
        guard let group, let item else { return }
        if index == -1 {
            item.select(nil, in: group)
        } else if index < group.options.count {
            item.select(group.options[index], in: group)
        }
    }

    private func refreshMediaSelectionGroups() async {
        guard let item else { return }
        audibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        legibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
    }

    private func installItemObservers() {
        guard let item else { return }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.state = .finished
            self.delegate?.playbackEngineDidFinish(self)
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let error = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                ?? PlaybackError.unknown
            self.state = .failed(error.localizedDescription)
            self.delegate?.playbackEngine(self, didFailWith: error)
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.playbackEngine(self, didUpdateTime: self.currentTime)
        }
    }

    private func removeItemObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        removeTimeObserver()
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
}
