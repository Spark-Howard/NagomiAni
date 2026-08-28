import AppKit
import OpenGL
import Cmpv

/// libmpv 的 OpenGL 渲染视图（画面上层）
final class MPVOpenGLView: NSOpenGLView {
    private weak var engine: MPVPlaybackEngine?
    private var renderContext: OpaquePointer?

    init(engine: MPVPlaybackEngine) {
        self.engine = engine

        let attrs: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24,
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAlphaSize), 8,
            0,
        ]
        let format = NSOpenGLPixelFormat(attributes: attrs)
        super.init(frame: .zero, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true

        // 关键：在引擎初始化时就建立 GL 上下文与 mpv 渲染上下文，
        // 否则 mpv 在 loadfile 时会回退到默认 VO（gpu→Vulkan），导致崩溃。
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        createRenderContext()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let renderContext {
            mpv_render_context_free(renderContext)
        }
    }

    override var isOpaque: Bool { true }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        // 若已在 init 中创建过则跳过
        guard renderContext == nil else { return }
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        createRenderContext()
    }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderContext else { return }
        openGLContext?.makeCurrentContext()

        let scale = window?.backingScaleFactor ?? 2
        let width = Int32(bounds.width * scale)
        let height = Int32(bounds.height * scale)

        var fbo = mpv_opengl_fbo(fbo: 0, w: width, h: height, internal_format: 0)
        var flipY: Int32 = 1

        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                let flags = mpv_render_context_update(renderContext)
                if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                    mpv_render_context_render(renderContext, &params)
                }
            }
        }
        openGLContext?.flushBuffer()
        mpv_render_context_report_swap(renderContext)
    }

    // MARK: - Private

    private func createRenderContext() {
        guard let handle = engine?.mpvHandle else { return }

        // 宏 MPV_RENDER_API_TYPE_OPENGL 在 Swift 中不可见，手动提供 "opengl" 字符串
        var apiTypeStorage = Array("opengl".utf8CString)
        var glInitParams = mpv_opengl_init_params(
            get_proc_address: nagomiru_gl_get_proc_address,
            get_proc_address_ctx: nil
        )
        var context: OpaquePointer?

        apiTypeStorage.withUnsafeMutableBufferPointer { buf in
            withUnsafeMutablePointer(to: &glInitParams) { glPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(
                        type: MPV_RENDER_PARAM_API_TYPE,
                        data: buf.baseAddress.map { UnsafeMutableRawPointer($0) }
                    ),
                    mpv_render_param(
                        type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                        data: UnsafeMutableRawPointer(glPtr)
                    ),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                guard mpv_render_context_create(&context, handle, &params) >= 0 else { return }
            }
        }

        guard let context else { return }
        renderContext = context

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(context, { ptr in
            guard let ptr else { return }
            let view = Unmanaged<MPVOpenGLView>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async {
                view.needsDisplay = true
            }
        }, selfPtr)
    }
}
