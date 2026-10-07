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
    /// 加载期用户/系统要求暂停：FILE_LOADED 到达后保持暂停（不自动播放）
    private var pauseAfterLoad = false
    private let loadLock = NSLock()
    private var loadContinuation: CheckedContinuation<Void, Error>?
    /// 加载代次：超时定时器只对发起它的那次 load 生效（否则线路 fallback /
    /// 快速换集时，上一次 load 的陈旧定时器会误杀正在进行的加载）
    private var loadGeneration = 0
    private var loadTimeoutWork: DispatchWorkItem?
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
        pauseAfterLoad = false
        cachedTime = 0
        cachedDuration = 0
        eofFlag = false
        pausedFlag = false
        trackList = []
        lastSubtitleTrackID = nil
        setState(.loading)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadLock.lock()
            // 重入保护：上一次 load 的续接还挂着时先以失败收场
            // （直接覆盖会令前一个 await engine.load 永久悬挂，其 Task 泄漏）
            if let previous = loadContinuation {
                loadContinuation = nil
                loadLock.unlock()
                previous.resume(throwing: PlaybackError.unknown)
                loadLock.lock()
            }
            loadGeneration += 1
            let generation = loadGeneration
            loadContinuation = cont
            loadLock.unlock()
            loadTimeoutWork?.cancel()
            // 超时兜底：FILE_LOADED 迟迟不来时不再无限转圈；只对本代次 load 生效，
            // 且超时必须上报 failed 状态，否则全部线路超时后 UI 永远停在"加载中"
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                #if DEBUG
                print("[mpv-engine] load TIMEOUT waiting FILE_LOADED")
                #endif
                self.setState(.failed("加载超时"))
                self.resolveLoad(.failure(PlaybackError.unknown))
            }
            loadTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            // loadfile 在后台线程执行：mpv_command 会阻塞到命令完成，
            // 若在主线程调用，切页/加载大文件时 UI 会卡死（转圈定格）
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                // 网络流参数：每次 load 显式设置/复位，避免上一个网络文件的头串味到下一个
                if let handle = self.mpvHandle {
                    if options.httpHeaders.isEmpty {
                        mpv_set_property_string(handle, "http-header-fields", "")
                    } else {
                        // mpv 列表属性按逗号分隔；头值含逗号的场景暂不存在（mock/常见站点均无）
                        let joined = options.httpHeaders
                            .map { "\($0.key): \($0.value)" }
                            .sorted()
                            .joined(separator: ",")
                        mpv_set_property_string(handle, "http-header-fields", joined)
                    }
                    mpv_set_property_string(handle, "user-agent", options.userAgent ?? "")
                }
                // http(s) URL 必须用 absoluteString：url.path 会丢掉 query（如带 token 的流地址）
                let target = url.isFileURL ? url.path : url.absoluteString
                let status = self.runCommand(["loadfile", target, "replace"])
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
        pauseAfterLoad = false
        if state == .finished || eofFlag {
            // 播完重播：keep-open=no 下 EOF 后 mpv 已进 idle、文件被卸载，
            // seek 无法生效——重新载入（事件驱动后续状态：START_FILE→loading→FILE_LOADED→play）
            eofFlag = false
            pausedFlag = false
            if let url = loadedURL {
                pendingAutoplay = true
                let target = url.isFileURL ? url.path : url.absoluteString
                runCommand(["loadfile", target, "replace"])
                return
            }
            seek(to: 0, completion: nil)
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
        if state == .loading {
            // 加载期的暂停意图：FILE_LOADED 到达后保持暂停
            // （否则加载完成的 autoplay 会覆盖它——切走模块后音频在后台自动出声）
            pauseAfterLoad = true
        }
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

        // 画质链路：mpv 默认缩放参数偏保守（bilinear 级降采样、无去带），
        // 感知上"画质发糊/一般"的主因。这里按 gpu-hq 档显式启用高质量链路：
        // spline36 上采样（锐利无振铃）、mitchell 降采样 + 纠正（缩小不闪 alias）、
        // sigmoid 上采样（抑制过冲光晕）、deband 治动漫天空/暗场的色带。
        // grain 调低（默认 48 会引入可见噪点，动画干净源反而显得"脏"）
        mpv_set_option_string(handle, "scale", "spline36")
        mpv_set_option_string(handle, "cscale", "spline36")
        mpv_set_option_string(handle, "dscale", "mitchell")
        mpv_set_option_string(handle, "correct-downscaling", "yes")
        mpv_set_option_string(handle, "linear-downscaling", "yes")
        mpv_set_option_string(handle, "sigmoid-upscaling", "yes")
        mpv_set_option_string(handle, "deband", "yes")
        mpv_set_option_string(handle, "deband-params", "grain=12")
        mpv_set_option_string(handle, "dither-depth", "auto")

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
                // 超时兜底已把本次加载判为失败时，迟到的加载成功不再接管状态
                // （否则 UI 显示失败、音频却自动播出来）
                guard !self.isFailed else { return }
                if self.pauseAfterLoad {
                    // 加载期被要求暂停：载入完成后保持暂停
                    self.state = .paused
                    var flag: Int32 = 1
                    if let handle = self.mpvHandle {
                        mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
                    }
                    return
                }
                self.state = .ready
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
            // 时长事件即时上报：ready 发布可能抢在时长属性送达之前（竞态），
            // 且加载期被暂停时状态直接进 paused 不经过 ready——UI 依赖该回调修正量程
            if value.isFinite, value > 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.playbackEngine(self, didUpdateDuration: value)
                }
            }

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
        guard cont != nil else { return }
        loadTimeoutWork?.cancel() // 加载已定局，撤销超时兜底
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
