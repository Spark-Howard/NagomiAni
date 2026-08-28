import AppKit
import SwiftUI

/// 将引擎提供的原生视频视图嵌入 SwiftUI
struct VideoSurfaceRepresentable: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
