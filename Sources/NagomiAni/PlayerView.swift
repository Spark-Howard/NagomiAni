import AppKit
import SwiftUI
import NagomiAniCore

struct PlayerView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        ZStack {
            if model.fileName == nil {
                emptyState
            } else {
                VideoSurfaceRepresentable(view: model.engine.videoSurface ?? NSView())
                statusOverlay
                controlsBar
                hiddenSpaceShortcut
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlayPause() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - 视图

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("把视频文件拖进来，或点击右上角打开")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("打开视频文件…") {
                model.openPanel()
            }
            .controlSize(.large)
        }
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
            Spacer()
        }
        .padding(.top, 12)
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

                Text(model.formattedCurrentTime)
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Slider(
                    value: Binding(
                        get: { model.isSeeking ? model.seekValue : model.currentTime },
                        set: { model.seekValue = $0 }
                    ),
                    in: 0...max(model.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            model.isSeeking = true
                        } else {
                            model.isSeeking = false
                            model.seek(to: model.seekValue)
                        }
                    }
                )

                Text(model.formattedDuration)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
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

    // MARK: - 拖拽

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                await self.model.load(url: url)
            }
        }
        return true
    }
}
