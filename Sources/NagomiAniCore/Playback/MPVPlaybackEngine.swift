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
    private let loadLock = NSLock()
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var trackList: [MediaTrack] = []
    private var loadedURL: URL?
    /// 最近选中的字幕轨道 id（关闭字幕后再开启时恢复）
    private var lastSubtitleTrackID: Int64?

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
        #if DEBUG
        print("[mpv-engine] load begin: \(url.lastPathComponent)")
        #endif

        loadedURL = url
        pendingAutoplay = options.autoplay
        cachedTime = 0
        cachedDuration = 0
        eofFlag = false
        pausedFlag = false
        trackList = []
        lastSubtitleTrackID = nil
        setState(.loading)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadLock.lock()
            loadContinuation = cont
            loadLock.unlock()
            // 超时兜底：FILE_LOADED 迟迟不来时不再无限转圈
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                #if DEBUG
                print("[mpv-engine] load TIMEOUT waiting FILE_LOADED")
                #endif
                self?.resolveLoad(.failure(PlaybackError.unknown))
            }
            // loadfile 在后台线程执行：mpv_command 会阻塞到命令完成，
            // 若在主线程调用，切页/加载大文件时 UI 会卡死（转圈定格）
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let status = self?.runCommand(["loadfile", url.path, "replace"]) ?? -1
                if status < 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.resolveLoad(.failure(PlaybackError.unknown))
                    }
                }
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
        if state == .ready {
            // replace 切换后 pause 属性值未变（仍为 0），mpv 不会发属性变化事件，
            // 这里主动补上 playing 状态
            setState(.playing)
        }
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
        trackList = []
        lastSubtitleTrackID = nil
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

    // MARK: - 字幕（内置 + 外挂）

    /// 挂载外部字幕文件（.srt/.ass/.vtt 等），成功返回 true
    public func addExternalSubtitle(url: URL) -> Bool {
        guard mpvHandle != nil, loadedURL != nil else { return false }
        let title = url.lastPathComponent
        let status = runCommand(["sub-add", url.path, "select", title])
        refreshTrackList()
        guard status >= 0 else { return false }
        // mpv_command 不返回 sub-add 的轨道 id，用轨道列表确认挂载成功
        if let track = subtitleTracks.first(where: {
            $0.externalFilename == url.path || $0.name == title
        }) {
            lastSubtitleTrackID = Int64(track.id)
            return true
        }
        return false
    }

    /// 开关字幕显示（false = 关闭，true = 恢复上次选择或自动选择）
    public func setSubtitleEnabled(_ enabled: Bool) {
        guard mpvHandle != nil else { return }
        if enabled {
            if let last = lastSubtitleTrackID, last > 0 {
                var id = last
                mpv_set_property(mpvHandle, "sid", MPV_FORMAT_INT64, &id)
            } else {
                mpv_set_property_string(mpvHandle, "sid", "auto")
            }
        } else {
            selectTrack(in: subtitleTracks, key: "sid", index: -1)
            return
        }
        refreshTrackList()
    }

    /// 字幕显示延迟（秒，正数延后）
    public var subtitleDelay: Double {
        get {
            guard let handle = mpvHandle else { return 0 }
            var value = 0.0
            mpv_get_property(handle, "sub-delay", MPV_FORMAT_DOUBLE, &value)
            return value.isFinite ? value : 0
        }
        set {
            guard let handle = mpvHandle else { return }
            var value = newValue
            mpv_set_property(handle, "sub-delay", MPV_FORMAT_DOUBLE, &value)
        }
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
            #if DEBUG
            print("[mpv-engine] START_FILE")
            #endif
            setState(.loading)

        case MPV_EVENT_FILE_LOADED:
            #if DEBUG
            print("[mpv-engine] FILE_LOADED")
            #endif
            resolveLoad(.success(()))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.isFailed { self.state = .ready }
                if self.pendingAutoplay { self.play() }
            }

        case MPV_EVENT_END_FILE:
            if let data = event.pointee.data {
                let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                #if DEBUG
                print("[mpv-engine] END_FILE reason=\(endFile.reason)")
                #endif
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
                } else if state == .loading, endFile.reason != MPV_END_FILE_REASON_STOP {
                    // stop 是 loadfile replace 切换时旧文件被替换的正常中断，
                    // 此时新文件正在加载，不能误判为失败
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
            notifyTracksChanged()

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
        loadLock.lock()
        let cont = loadContinuation
        loadContinuation = nil
        loadLock.unlock()
        cont?.resume(with: result)
    }

    // MARK: - 轨道

    private func selectTrack(in tracks: [MediaTrack], key: String, index: Int) {
        guard let handle = mpvHandle else { return }
        if index == -1 {
            if key == "sid", let current = subtitleTracks.first(where: { $0.isSelected }) {
                lastSubtitleTrackID = Int64(current.id)
            }
            mpv_set_property_string(handle, key, "no")
        } else if tracks.indices.contains(index) {
            var id = Int64(tracks[index].id)
            mpv_set_property(handle, key, MPV_FORMAT_INT64, &id)
            if key == "sid" { lastSubtitleTrackID = id }
        }
        refreshTrackList()
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
            var external = false
            var externalFilename: String?

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
                case "external":
                    external = value.u.flag != 0
                case "external-filename":
                    externalFilename = stringValue(value)
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

            // 外挂字幕没有 title 时，用文件名作为显示名
            let displayName: String?
            if let title, !title.isEmpty {
                displayName = title
            } else if let externalFilename {
                displayName = URL(fileURLWithPath: externalFilename).lastPathComponent
            } else {
                displayName = lang
            }

            result.append(MediaTrack(
                id: id,
                kind: kind,
                name: displayName,
                language: lang,
                isSelected: selected,
                isExternal: external,
                externalFilename: externalFilename
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

    // MARK: - 轨道刷新

    /// 立即读取 track-list 属性并广播（用于 sub-add / 选择变更后强制同步）
    private func refreshTrackList() {
        guard let handle = mpvHandle else { return }
        var node = mpv_node()
        let status = mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &node)
        guard status >= 0 else { return }
        trackList = parseTrackList(node)
        mpv_free_node_contents(&node)
        notifyTracksChanged()
    }

    private func notifyTracksChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.playbackEngineDidUpdateTracks(self)
        }
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
