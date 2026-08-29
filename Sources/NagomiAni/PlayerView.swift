import AppKit
import SwiftUI
import NagomiAniCore

struct PlayerView: View {
    @ObservedObject var model: PlayerModel

    /// 底部控制条（进度条/按钮）可见性：鼠标移入底部热区呼出，移出后自动隐藏
    @State private var bottomVisible = true
    /// 顶部叠加层（文件名/关联状态/同步消息）可见性：打开视频后短暂显示
    @State private var topVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isFullScreen = false

    /// 打开视频/操作后自动隐藏的延时
    private let autoHideDelay: UInt64 = 3_000_000_000
    /// 底部呼出热区高度（pt）
    private let bottomHotZone: CGFloat = 90

    var body: some View {
        ZStack {
            if model.fileName == nil {
                emptyState
            } else {
                VideoSurfaceRepresentable(view: model.engine.videoSurface ?? NSView())
                GeometryReader { geo in
                    ZStack {
                        VStack {
                            topBar
                                .opacity(topVisible ? 1 : 0)
                                .allowsHitTesting(topVisible)
                            Spacer()
                        }
                        statusOverlay
                        VStack {
                            Spacer()
                            controlsBar
                                .opacity(bottomVisible ? 1 : 0)
                                .allowsHitTesting(bottomVisible)
                        }
                    }
                    .onContinuousHover { phase in
                        handleHover(phase, in: geo.size)
                    }
                }
            }
            // 全局快捷键（空状态与播放中均可用）
            hiddenSpaceShortcut
            hiddenOpenShortcut
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 空状态用系统背景色（与番库/Bangumi 页一致，切换不晃眼）；
        // 播放中保持黑色（视频画面即黑色，黑边正常）
        .background(model.fileName == nil ? Color(nsColor: .windowBackgroundColor) : Color.black)
        .contentShape(Rectangle())
        .onTapGesture {
            model.togglePlayPause()
            showAllTemporarily()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $model.isBindSheetPresented) {
            BindSubjectView(model: model)
        }
        // 加载中/出错/播完保持控制条可见；开始播放后 3 秒自动隐藏
        .task(id: model.state) {
            switch model.state {
            case .loading, .failed, .finished:
                showAllKeepVisible()
            case .ready, .playing:
                scheduleHideAll()
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    // MARK: - 全屏

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: - 控制条显隐

    private func handleHover(_ phase: HoverPhase, in size: CGSize) {
        switch phase {
        case .active(let location):
            // SwiftUI local 坐标原点在左上角、y 向下 → 底部热区是 y 接近高度处
            if location.y > size.height - bottomHotZone {
                // 鼠标在底部热区：上方番目信息 + 下方进度条一起呼出并保持
                showAllKeepVisible()
            } else {
                scheduleHideAll()
            }
        case .ended:
            scheduleHideAll()
        }
    }

    /// 上方番目信息 + 下方进度条一起显示并保持（加载中/出错/播完/鼠标在底部热区）
    private func showAllKeepVisible() {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            topVisible = true
            bottomVisible = true
        }
    }

    /// 上方 + 下方短暂显示后一起隐藏（点击画面等操作）
    private func showAllTemporarily() {
        showAllKeepVisible()
        scheduleHideAll()
    }

    /// 上方 + 下方 3 秒后一起隐藏（控制条常驻，仅透明度变化，进度条位置不跳动）
    private func scheduleHideAll() {
        hideTask?.cancel()
        hideTask = Task { [self] in
            try? await Task.sleep(nanoseconds: autoHideDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.topVisible = false
                    self.bottomVisible = false
                }
            }
        }
    }

    // MARK: - 视图

    /// 空状态：醒目提示用户选择视频文件（背景跟随系统，自动适配深浅色）
    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("选择一部番剧开始播放")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text("拖拽视频文件到窗口，或点击下方按钮选择")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                model.openPanel()
            } label: {
                Label("选择视频文件…", systemImage: "folder")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// 顶部：文件名 + Bangumi 关联状态/按钮（从番库打开时隐藏关联栏）
    private var topBar: some View {
        HStack(spacing: 10) {
            Text(model.fileName ?? "")
                .lineLimit(1)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .truncationMode(.middle)

            Spacer()

            if !model.hideBindingBar {
                if let subject = model.boundSubject {
                    Label(subject.nameCN ?? subject.name ?? "已关联", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                    Button("更换") {
                        model.isBindSheetPresented = true
                    }
                    .controlSize(.small)
                    Button {
                        model.unbind()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("解除关联")
                } else {
                    Button("关联 Bangumi 条目") {
                        model.isBindSheetPresented = true
                    }
                    .controlSize(.small)
                }
            }

            // 打开文件（原窗口工具栏按钮移入此处，保证三页顶部栏高度一致）
            Button {
                model.openPanel()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("打开文件")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private var statusOverlay: some View {
        VStack {
            if model.isLoading {
                ProgressView("加载中…")
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if let message = model.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            if topVisible, let message = model.syncMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .transition(.opacity)
            }
            Spacer()
        }
        .padding(.top, 56)
    }

    private var controlsBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Text(model.formattedDisplayTime)
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Slider(
                    value: Binding(
                        get: { model.sliderValue },
                        set: { model.sliderValue = $0 }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            model.isSeeking = true
                        } else {
                            model.isSeeking = false
                            model.seek(to: model.sliderValue)
                        }
                    }
                )

                Text(model.formattedDuration)
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                audioMenu
                subtitleMenu
                Button {
                    toggleFullScreen()
                } label: {
                    Image(systemName: isFullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(isFullScreen ? "退出全屏" : "进入全屏")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }

    // MARK: - 音轨 / 字幕菜单

    private var audioMenu: some View {
        Menu {
            if model.audioTracks.isEmpty {
                Text("无音轨")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.audioTracks.enumerated()), id: \.offset) { index, track in
                    Button {
                        model.selectAudioTrack(index)
                    } label: {
                        if track.isSelected {
                            Label(trackName(track, index: index), systemImage: "checkmark")
                        } else {
                            Text(trackName(track, index: index))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2")
                .font(.title3)
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("音轨")
    }

    private var subtitleMenu: some View {
        // 已挂载的外挂字幕不在此列出（挂载即生效），菜单只显示内置字幕轨
        let builtinTracks = model.subtitleTracks.enumerated().filter { !$0.element.isExternal }
        return Menu {
            Button {
                model.setSubtitleEnabled(false)
            } label: {
                if model.subtitleTracks.contains(where: { $0.isSelected }) {
                    Text("关闭字幕")
                } else {
                    Label("关闭字幕", systemImage: "checkmark")
                }
            }

            Divider()

            if builtinTracks.isEmpty {
                Text("无内置字幕轨")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(builtinTracks, id: \.offset) { pair in
                    Button {
                        model.selectSubtitleTrack(pair.offset)
                    } label: {
                        if pair.element.isSelected {
                            Label(trackName(pair.element, index: pair.offset), systemImage: "checkmark")
                        } else {
                            Text(trackName(pair.element, index: pair.offset))
                        }
                    }
                }
            }

            Divider()

            Button {
                model.loadExternalSubtitle()
            } label: {
                Label("加载外挂字幕文件…", systemImage: "plus.circle")
            }

            Divider()

            Menu("字幕延迟 \(model.formattedSubtitleDelay)") {
                Button("提前 0.5 秒") { model.adjustSubtitleDelay(by: -0.5) }
                Button("延后 0.5 秒") { model.adjustSubtitleDelay(by: 0.5) }
                Button("重置") { model.resetSubtitleDelay() }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.title3)
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕")
    }

    private func trackName(_ track: MediaTrack, index: Int) -> String {
        var name = track.name ?? "轨道 \(index + 1)"
        if track.isExternal {
            name += "（外挂）"
        }
        return name
    }

    /// 空格键播放/暂停（隐藏按钮承载快捷键）
    private var hiddenSpaceShortcut: some View {
        Button("toggle") {
            model.togglePlayPause()
        }
        .keyboardShortcut(.space, modifiers: [])
        .opacity(0)
        .frame(width: 1, height: 1)
    }

    /// Cmd+O 打开文件（隐藏按钮承载快捷键）
    private var hiddenOpenShortcut: some View {
        Button("open") {
            model.openPanel()
        }
        .keyboardShortcut("o", modifiers: [.command])
        .opacity(0)
        .frame(width: 1, height: 1)
    }

    // MARK: - 拖拽

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                if PlayerModel.isSubtitleFile(url) {
                    // 拖入的是字幕文件 → 挂载为外挂字幕
                    self.model.loadExternalSubtitle(url: url)
                } else {
                    await self.model.load(url: url)
                }
            }
        }
        return true
    }
}
