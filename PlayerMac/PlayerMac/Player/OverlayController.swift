import AppKit
import Observation
import SwiftUI

/// Controls overlay appears on mouse movement and hides after 3s idle.
/// While paused or user interacts with controls, overlay remains visible.
@MainActor @Observable
final class OverlayController {
    static let idleDelay: Duration = .seconds(3)

    enum Interaction: Hashable { case hover, scrubbing, popover }

    private(set) var isVisible = true
    /// Mouse over panel, dragging slider, or popover open.
    private(set) var interactions: Set<Interaction> = []
    var isInteracting: Bool { !interactions.isEmpty }
    /// Whether controls can hide: video loaded and playing.
    var canHide = false {
        didSet { if canHide != oldValue { reschedule() } }
    }
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var isPointerInside = false
    @ObservationIgnored private let setCursorHidden: @MainActor (Bool) -> Void

    init(setCursorHidden: @escaping @MainActor (Bool) -> Void = NSCursor.setHiddenUntilMouseMoves) {
        self.setCursorHidden = setCursorHidden
    }

    isolated deinit {
        hideTask?.cancel()
        setCursorHidden(false)
    }

    func set(_ interaction: Interaction, active: Bool) {
        let changed =
            active
            ? interactions.insert(interaction).inserted : interactions.remove(interaction) != nil
        if changed { reschedule() }
    }

    func activity() {
        isPointerInside = true
        show()
        reschedule()
    }

    /// Mouse exited window: hide faster like QuickTime.
    func pointerLeft() {
        isPointerInside = false
        setCursorHidden(false)
        reschedule(after: .milliseconds(600))
    }

    private func reschedule(after delay: Duration = OverlayController.idleDelay) {
        hideTask?.cancel()
        guard canHide, !isInteracting else {
            show()
            return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.45)) { self.isVisible = false }
            // Hide cursor only over window to avoid interfering with other apps.
            if self.isPointerInside { self.setCursorHidden(true) }
        }
    }

    private func show() {
        setCursorHidden(false)
        if !isVisible { withAnimation(.easeOut(duration: 0.2)) { isVisible = true } }
    }
}
