import AppKit
import SwiftUI

struct VideoView: NSViewRepresentable {
    let videoLayer: VideoLayer

    func makeNSView(context: Context) -> VideoHostView { VideoHostView(videoLayer: videoLayer) }
    func updateNSView(_ nsView: VideoHostView, context: Context) {}
}

final class VideoHostView: NSView {
    private let videoLayer: VideoLayer

    init(videoLayer: VideoLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        layer = videoLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }

    override func layout() {
        super.layout()
        videoLayer.requestDisplay()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Root layer size in layer-hosting is determined by application.
        updateGeometry()
    }

    private func updateGeometry() {
        videoLayer.updateGeometry(frame: bounds, scale: window?.backingScaleFactor ?? 1)
    }
}
