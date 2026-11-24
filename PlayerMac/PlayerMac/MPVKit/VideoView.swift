import AppKit
import QuartzCore
import SwiftUI

struct VideoView: NSViewRepresentable {
    let videoLayer: VideoLayer?

    func makeNSView(context: Context) -> VideoHostView { VideoHostView(videoLayer: videoLayer) }

    func updateNSView(_ nsView: VideoHostView, context: Context) {
        nsView.setVideoLayer(videoLayer)
    }
}

final class VideoHostView: NSView {
    private var videoLayer: VideoLayer?

    init(videoLayer: VideoLayer? = nil) {
        super.init(frame: .zero)
        let hostLayer = CALayer()
        hostLayer.backgroundColor = NSColor.black.cgColor
        layer = hostLayer
        wantsLayer = true
        setVideoLayer(videoLayer)
    }

    required init?(coder: NSCoder) { nil }

    func setVideoLayer(_ newLayer: VideoLayer?) {
        guard videoLayer !== newLayer else { return }
        if let previous = videoLayer {
            previous.releaseBacking()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previous.removeFromSuperlayer()
            CATransaction.commit()
        }
        videoLayer = newLayer
        guard let newLayer, let hostLayer = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newLayer.autoresizingMask = []
        hostLayer.addSublayer(newLayer)
        CATransaction.commit()
        if window != nil {
            updateGeometry()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            videoLayer?.releaseBacking()
        } else {
            updateGeometry()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    override func layout() {
        super.layout()
        videoLayer?.requestDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGeometry()
    }

    private func updateGeometry() {
        videoLayer?.updateGeometry(frame: bounds, scale: window?.backingScaleFactor ?? 1)
    }
}
