import AppKit
import Foundation
import Cmpv

/// 基于 libmpv 的播放内核（阶段二实现，支持 MKV/ASS 等）
public final class MPVPlaybackEngine: PlaybackEngine {
    public static var capabilities: PlaybackCapabilities = [
        .audioTrackSelection, .subtitleTrackSelection, .accurateSeek
    ]

    public weak var delegate: PlaybackEngineDelegate?

    public private(set) var state: PlaybackState = .idle {
        didSet { delegate?.playbackEngine(self, didChangeState: state) }
    }

    // MARK: - 内部状态

    private(set) var mpvHandle: OpaquePointer?
    private var eventLoopActive = false
    private var pausedFlag = false
    private var eofFlag = false
    private var cachedDuration: Double = 0
    private var cachedTime: Double = 0
    private var pendingAutoplay = true
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var trackList: [MediaTrack] = []
    private var loadedURL: URL?

    // MARK: - 渲染视图

    public var videoSurface: NSView? { renderView }
    private lazy var renderView: MPVOpenGLView = MPVOpenGLView(engine: self)

    // MARK: - 生命周期

    public init() {
        guard let handle = mpv_create() else {
            state = .failed("无法创建播放内核")
            return
        }
        mpvHandle = handle
        configure()
        // 提前创建渲染视图与 mpv 渲染上下文，
        // 确保播放开始前 render API 已就绪（否则 mpv 回退到默认 VO 会崩溃）
        _ = renderView
    }

    deinit {
        eventLoopActive = false
        if let handle = mpvHandle {
            mpv_wakeup(handle)
            mpv_terminate_destroy(handle)
            mpvHandle = nil
        }
    }

    // MARK: - PlaybackEngine

    public var duration: Double { cachedDuration }

    public var currentTime: Double { cachedTime }

    public var isPlaying: Bool {
        !pausedFlag && !eofFlag && (state == .playing || state == .ready || state == .loading)
    }

    public var rate: Float {
        get {
            guard let handle = mpvHandle else { return 1 }
            var value = 1.0
            mpv_get_property(handle, "speed", MPV_FORMAT_DOUBLE, &value)
            return Float(value)
        }
        set {
            guard let handle = mpvHandle else { return }
            var value = Double(newValue)
            mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &value)
        }
    }

    public func load(url: URL, options: PlaybackOptions) async throws {
        guard let handle = mpvHandle else { throw PlaybackError.unknown }

        loadedURL = url
        pendingAutoplay = options.autoplay
        cachedTime = 0
        cachedDuration = 0
        eofFlag = false
        pausedFlag = false
        setState(.loading)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            let status = runCommand(["loadfile", url.path, "replace"])
            if status < 0 {
                loadContinuation = nil
                cont.resume(throwing: PlaybackError.unknown)
            }
        }

        if options.startTime > 0 {
            seek(to: options.startTime, completion: nil)
        }
    }

    public func play() {
        guard let handle = mpvHandle else { return }
        if state == .finished || eofFlag {
            // 播完重播：回到开头并强制切到播放态（eof-reached 属性可能有延迟）
            eofFlag = false
            seek(to: 0, completion: nil)
            pausedFlag = false
            setState(.playing)
        }
        pausedFlag = false
        var flag: Int32 = 0
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func pause() {
        guard let handle = mpvHandle else { return }
        pausedFlag = true
        var flag: Int32 = 1
        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
    }

    public func stop() {
        guard let handle = mpvHandle else { return }
        eofFlag = false
        pausedFlag = false
        cachedTime = 0
        cachedDuration = 0
        loadedURL = nil
        runCommand(["stop"])
        setState(.idle)
    }

    public func seek(to seconds: Double, completion: ((Bool) -> Void)?) {
        guard mpvHandle != nil else {
            completion?(false)
            return
        }
        let status = runCommand(["seek", String(format: "%.3f", seconds), "absolute"])
        completion?(status >= 0)
    }

    public var audioTracks: [MediaTrack] {
        trackList.filter { $0.kind == .audio }
    }

    public var subtitleTracks: [MediaTrack] {
        trackList.filter { $0.kind == .subtitle }
    }

    public func selectAudioTrack(_ index: Int) {
        selectTrack(in: audioTracks, key: "aid", index: index)
    }

    public func selectSubtitleTrack(_ index: Int) {
        selectTrack(in: subtitleTracks, key: "sid", index: index)
    }

    // MARK: - 配置

    private func configure() {
        guard let handle = mpvHandle else { return }

        // 显式锁定 libmpv 渲染，禁止回退到 gpu/Vulkan 等默认 VO
        mpv_set_option_string(handle, "vo", "libmpv")
        mpv_set_option_string(handle, "hwdec", "videotoolbox")
        mpv_set_option_string(handle, "hwdec-codecs", "all")
        mpv_set_option_string(handle, "audio", "coreaudio")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "osd-level", "0")
        mpv_set_option_string(handle, "keep-open", "no")
        mpv_set_option_string(handle, "sub-auto", "fuzzy")
        mpv_set_option_string(handle, "audio-file-auto", "no")
        mpv_set_option_string(handle, "volume", "100")

        if mpv_initialize(handle) < 0 {
            setState(.failed("初始化播放内核失败"))
            return
        }

        mpv_request_log_messages(handle, "warn")
        observe("time-pos", MPV_FORMAT_DOUBLE)
        observe("duration", MPV_FORMAT_DOUBLE)
        observe("pause", MPV_FORMAT_FLAG)
        observe("eof-reached", MPV_FORMAT_FLAG)
        observe("track-list", MPV_FORMAT_NODE)

        startEventLoop()
    }

    private func observe(_ name: String, _ format: mpv_format) {
        mpv_observe_property(mpvHandle, 0, name, format)
    }

    // MARK: - 事件循环

    private func startEventLoop() {
        guard let handle = mpvHandle, !eventLoopActive else { return }
        eventLoopActive = true
        let thread = Thread { [weak self] in
            self?.eventLoop(handle)
        }
        thread.name = "NagomiAni.mpv"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func eventLoop(_ handle: OpaquePointer) {
        while eventLoopActive {
            guard let event = mpv_wait_event(handle, 0.15) else { continue }
            handleEvent(event)
            if event.pointee.event_id == MPV_EVENT_SHUTDOWN { break }
        }
    }

    private func handleEvent(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_START_FILE:
            setState(.loading)

        case MPV_EVENT_FILE_LOADED:
            resolveLoad(.success(()))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isFailed { self.state = .ready }
                if self.pendingAutoplay { self.play() }
            }

        case MPV_EVENT_END_FILE:
            if let data = event.pointee.data {
                let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if endFile.reason == MPV_END_FILE_REASON_EOF {
                    resolveLoad(.success(()))
                    eofFlag = true
                    setState(.finished)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.playbackEngineDidFinish(self)
                    }
                } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                    resolveLoad(.failure(PlaybackError.unknown))
                    setState(.failed("播放出错"))
                } else if state == .loading {
                    // stop / redirect 等异常中断
                    resolveLoad(.failure(PlaybackError.unknown))
                    setState(.failed("播放失败"))
                }
            }

        case MPV_EVENT_PROPERTY_CHANGE:
            propertyChanged(event.pointee)

        case MPV_EVENT_LOG_MESSAGE:
            #if DEBUG
            if let data = event.pointee.data {
                let log = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                if let text = log.text {
                    print("[mpv] \(String(cString: text))")
                }
            }
            #endif

        default:
            break
        }
    }

    private func propertyChanged(_ event: mpv_event) {
        guard let data = event.data else { return }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard let namePtr = property.name, let valueData = property.data else { return }
        let name = String(cString: namePtr)

        switch name {
        case "time-pos":
            let value = valueData.assumingMemoryBound(to: Double.self).pointee
            cachedTime = value.isFinite ? value : 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.playbackEngine(self, didUpdateTime: self.cachedTime)
            }

        case "duration":
            let value = valueData.assumingMemoryBound(to: Double.self).pointee
            cachedDuration = value.isFinite ? value : 0

        case "pause":
            pausedFlag = valueData.assumingMemoryBound(to: Int32.self).pointee != 0
            updateStateFromFlags()

        case "eof-reached":
            eofFlag = valueData.assumingMemoryBound(to: Int32.self).pointee != 0
            updateStateFromFlags()

        case "track-list":
            let node = valueData.assumingMemoryBound(to: mpv_node.self).pointee
            trackList = parseTrackList(node)

        default:
            break
        }
    }

    private func updateStateFromFlags() {
        // idle/loading/failed 属于加载期中间态，不参与播放/暂停切换
        guard state != .idle, state != .loading, !isFailed else { return }

        let newState: PlaybackState
        if eofFlag {
            newState = .finished
        } else if pausedFlag {
            newState = .paused
        } else {
            // ready / paused / finished 解除暂停后都应回到 playing
            newState = .playing
        }
        if newState != state { setState(newState) }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func setState(_ newState: PlaybackState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = newState
        }
    }

    private func resolveLoad(_ result: Result<Void, Error>) {
        guard let cont = loadContinuation else { return }
        loadContinuation = nil
        cont.resume(with: result)
    }

    // MARK: - 轨道

    private func selectTrack(in tracks: [MediaTrack], key: String, index: Int) {
        guard let handle = mpvHandle else { return }
        if index == -1 {
            mpv_set_property_string(handle, key, "no")
        } else if tracks.indices.contains(index) {
            var id = Int64(tracks[index].id)
            mpv_set_property(handle, key, MPV_FORMAT_INT64, &id)
        }
    }

    private func parseTrackList(_ node: mpv_node) -> [MediaTrack] {
        guard node.format == MPV_FORMAT_NODE_ARRAY, let listPtr = node.u.list else { return [] }
        let list = listPtr.pointee
        var result: [MediaTrack] = []

        for i in 0..<Int(list.num) {
            let entry = list.values![i]
            guard entry.format == MPV_FORMAT_NODE_MAP, let mapPtr = entry.u.list else { continue }
            let map = mapPtr.pointee

            var type = ""
            var id = 0
            var title: String?
            var lang: String?
            var selected = false

            for j in 0..<Int(map.num) {
                let key = map.keys![j].map { String(cString: $0) } ?? ""
                let value = map.values![j]
                switch key {
                case "type":
                    type = stringValue(value) ?? ""
                case "id":
                    id = intValue(value) ?? 0
                case "title":
                    title = stringValue(value)
                case "lang":
                    lang = stringValue(value)
                case "selected":
                    selected = value.u.flag != 0
                default:
                    break
                }
            }

            let kind: MediaTrack.MediaKind
            switch type {
            case "audio": kind = .audio
            case "sub": kind = .subtitle
            default: continue // video 等暂不展示
            }

            result.append(MediaTrack(
                id: id,
                kind: kind,
                name: title ?? lang,
                language: lang,
                isSelected: selected
            ))
        }
        return result
    }

    private func stringValue(_ node: mpv_node) -> String? {
        guard node.format == MPV_FORMAT_STRING, let ptr = node.u.string else { return nil }
        return String(cString: ptr)
    }

    private func intValue(_ node: mpv_node) -> Int? {
        guard node.format == MPV_FORMAT_INT64 else { return nil }
        return Int(node.u.int64)
    }

    // MARK: - 工具

    @discardableResult
    private func runCommand(_ args: [String]) -> Int32 {
        guard let handle = mpvHandle else { return -1 }
        let argv = buildArgv(args)
        defer { freeArgv(argv) }
        return argv.withUnsafeBufferPointer { buf in
            mpv_command(handle, UnsafeMutablePointer(mutating: buf.baseAddress))
        }
    }

    private func buildArgv(_ args: [String]) -> [UnsafePointer<CChar>?] {
        var pointers: [UnsafePointer<CChar>?] = args.map { strdup($0).map { UnsafePointer($0) } }
        pointers.append(nil)
        return pointers
    }

    private func freeArgv(_ args: [UnsafePointer<CChar>?]) {
        for ptr in args {
            free(UnsafeMutablePointer(mutating: ptr))
        }
    }
}
