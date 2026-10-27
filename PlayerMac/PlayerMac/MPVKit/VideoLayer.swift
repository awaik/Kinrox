import OpenGL
import QuartzCore

// CALayer permits background rendering. Access to render and display serialized
// by shared locks, including for presentation copies of layer.
final class VideoLayer: CAOpenGLLayer, @unchecked Sendable {
    let resources: MPVRenderContext

    init(resources: MPVRenderContext) {
        self.resources = resources
        super.init()
        isAsynchronous = false
        isOpaque = true
        needsDisplayOnBoundsChange = true
        contentsGravity = .resizeAspect
        resources.installCallback(for: self)
    }

    override init(layer: Any) {
        resources = (layer as! VideoLayer).resources
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { nil }

    @MainActor
    func updateGeometry(frame: CGRect, scale: CGFloat) {
        guard self.frame != frame || contentsScale != scale else { return }
        resources.displayLock.withLock {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.frame = frame
            contentsScale = scale
            setNeedsDisplay()
            CATransaction.commit()
        }
        // setFrameSize may execute inside external AppKit transaction.
        // Return control to caller before flushing on main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            resources.displayLock.withLock { CATransaction.flush() }
            requestDisplay()
        }
    }

    func requestDisplay() {
        resources.queue.async { [weak self] in self?.display() }
    }

    override func display() {
        resources.displayLock.withLock {
            let frames = resources.renderedFrameCount
            // GCD thread has no run loop that would complete implicit CA transaction.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Synchronous CAOpenGLLayer updates buffer only after invalidation.
            super.setNeedsDisplay()
            super.display()
            CATransaction.commit()
            // On main thread display may be invoked by CA commit itself.
            if !Thread.isMainThread { CATransaction.flush() }
            if resources.renderedFrameCount == frames { resources.skipFrameIfNeeded() }
        }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(resources.pixelFormat)
        return resources.pixelFormat
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(resources.context)
        return resources.context
    }

    override func draw(
        inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        resources.withContext {
            resources.draw()
            super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
        }
    }
}
