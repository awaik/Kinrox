import Foundation
import OpenGL.GL3
import QuartzCore
import os

// CGL objects are immutable; renderContext and counters accessible under CGL lock only.
// displayLock shared for layer and its presentation copies; client API not invoked here.
final class MPVRenderContext: @unchecked Sendable {
    let pixelFormat: CGLPixelFormatObj
    let context: CGLContextObj
    let queue = DispatchQueue(label: "kinrox.mpv.render", qos: .userInteractive)
    let displayLock = NSRecursiveLock()
    private var renderContext: OpaquePointer?
    private var lastSize: [GLint] = []
    private var frameCount = 0
    private let logger = Logger(subsystem: "app.kinrox.player", category: "render")

    init(handle: OpaquePointer) throws {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        let formatError = CGLChoosePixelFormat(attributes, &format, &count)
        guard formatError == kCGLNoError, let format else {
            throw MPVError("Failed to create OpenGL format: \(formatError.rawValue)")
        }
        pixelFormat = format
        var glContext: CGLContextObj?
        let contextError = CGLCreateContext(format, nil, &glContext)
        guard contextError == kCGLNoError, let glContext else {
            CGLReleasePixelFormat(format)
            throw MPVError("Failed to create OpenGL context: \(contextError.rawValue)")
        }
        context = glContext
        do {
            try queue.sync {
                try withContext {
                    var gl = mpv_opengl_init_params(
                        get_proc_address: { _, name in
                            guard let name,
                                let bundle = CFBundleGetBundleWithIdentifier(
                                    "com.apple.opengl" as CFString)
                            else { return nil }
                            return CFBundleGetFunctionPointerForName(
                                bundle, String(cString: name) as CFString)
                        }, get_proc_address_ctx: nil)
                    try "opengl".withCString { api in
                        try withUnsafeMutablePointer(to: &gl) { paramsPointer in
                            var params = [
                                mpv_render_param(
                                    type: MPV_RENDER_PARAM_API_TYPE,
                                    data: UnsafeMutableRawPointer(mutating: api)),
                                mpv_render_param(
                                    type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                                    data: paramsPointer),
                                mpv_render_param(),
                            ]
                            // ADVANCED_CONTROL disabled for now: validating basic M1 cycle first.
                            try MPVError.check(
                                mpv_render_context_create(&renderContext, handle, &params),
                                "Video output initialization")
                        }
                    }
                }
            }
        } catch {
            // All fields initialized: Swift will invoke deinit even upon throw.
            throw error
        }
    }

    deinit {
        assert(renderContext == nil, "mpv_render_context must be freed first")
        CGLReleaseContext(context)
        CGLReleasePixelFormat(pixelFormat)
    }

    func installCallback(for layer: VideoLayer) {
        withContext {
            guard let renderContext else { return }
            mpv_render_context_set_update_callback(
                renderContext,
                { pointer in
                    guard let pointer else { return }
                    let layer = Unmanaged<VideoLayer>.fromOpaque(pointer).takeUnretainedValue()
                    layer.requestDisplay()
                }, Unmanaged.passUnretained(layer).toOpaque())
        }
    }

    func withContext<T>(_ body: () throws -> T) rethrows -> T {
        CGLLockContext(context)
        let previous = CGLGetCurrentContext()
        CGLSetCurrentContext(context)
        defer {
            CGLSetCurrentContext(previous)
            CGLUnlockContext(context)
        }
        return try body()
    }

    func draw() {
        withContext {
            guard let renderContext else {
                glClearColor(0, 0, 0, 1)
                glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                return
            }
            _ = mpv_render_context_update(renderContext)
            var framebuffer: GLint = 0
            var viewport = [GLint](repeating: 0, count: 4)
            glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
            glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
            guard viewport[2] > 0, viewport[3] > 0 else { return }
            var fbo = mpv_opengl_fbo(
                fbo: framebuffer, w: viewport[2], h: viewport[3], internal_format: 0)
            var flip: Int32 = 1
            var blockForTargetTime: Int32 = 0
            let status = withUnsafeMutablePointer(to: &fbo) { fboPointer in
                withUnsafeMutablePointer(to: &flip) { flipPointer in
                    withUnsafeMutablePointer(to: &blockForTargetTime) { blockPointer in
                        var params = [
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPointer),
                            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                            mpv_render_param(
                                type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: blockPointer),
                            mpv_render_param(),
                        ]
                        return mpv_render_context_render(renderContext, &params)
                    }
                }
            }
            if status < 0 {
                logger.error("Render error: \(status)")
            } else {
                frameCount += 1
                if lastSize != viewport {
                    lastSize = viewport
                    logger.info("Video buffer: \(viewport[2])×\(viewport[3]) pixels")
                }
            }
            glFlush()
        }
    }

    var renderedFrameCount: Int { withContext { frameCount } }

    var renderedSize: CGSize {
        withContext {
            guard lastSize.count == 4 else { return .zero }
            return CGSize(width: Int(lastSize[2]), height: Int(lastSize[3]))
        }
    }

    func skipFrameIfNeeded() {
        withContext {
            guard let renderContext,
                mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)
                    != 0
            else { return }
            // In minimized window CA might not invoke draw; flush mpv frame queue.
            var skip: Int32 = 1
            withUnsafeMutablePointer(to: &skip) { pointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: pointer),
                    mpv_render_param(),
                ]
                _ = mpv_render_context_render(renderContext, &params)
            }
        }
    }

    func shutdown() {
        queue.sync {
            displayLock.withLock {
                withContext {
                    guard let renderContext else { return }
                    mpv_render_context_set_update_callback(renderContext, nil, nil)
                    mpv_render_context_free(renderContext)
                    self.renderContext = nil
                    logger.info("Render context released; frames: \(self.frameCount)")
                }
            }
        }
    }
}
