import ActivityKit
import Foundation
import os

/// Starts, updates and ends the system card; a fake replaces it in tests.
@MainActor
protocol LockScreenPresenter: AnyObject {
    var isShowing: Bool { get }
    var initialContent: LockScreenAttributes.ContentState? { get }
    func show(_ content: LockScreenAttributes.ContentState, staleDate: Date?)
    /// `dismissAt == nil` removes the card immediately.
    func end(_ content: LockScreenAttributes.ContentState?, dismissAt: Date?)
}

/// Decides what the card shows. Content always comes from state confirmed by the Mac.
@MainActor
final class LockScreenActivityController {
    typealias Content = LockScreenAttributes.ContentState
    /// Owner decision 2026-11-11: the card goes away after an hour on pause.
    static let pauseLifetime: TimeInterval = 3600

    private let presenter: any LockScreenPresenter
    private let now: () -> Date
    private(set) var content: Content?
    private(set) var pausedSince: Date?
    /// A pressed button keeps its indicator until the Mac confirms the command.
    private(set) var sending: LockScreenAction?

    init(presenter: any LockScreenPresenter, now: @escaping () -> Date = Date.init) {
        self.presenter = presenter
        self.now = now
        content = presenter.initialContent
        if let content, content.paused { pausedSince = content.pausedSince ?? content.anchor }
    }

    var isShowing: Bool { presenter.isShowing }

    /// `nil` means nothing is playing on the Mac.
    func sync(_ desired: Content?) {
        guard var desired else {
            end()
            return
        }
        desired.phase = sending == nil ? .live : .sending
        desired.sending = sending
        if desired.paused {
            if pausedSince == nil || content?.paused == false { pausedSince = desired.anchor }
        } else {
            pausedSince = nil
        }
        desired.pausedSince = pausedSince
        if let pausedSince, now().timeIntervalSince(pausedSince) >= Self.pauseLifetime {
            end()
            return
        }
        guard presenter.isShowing == false || needsUpdate(desired) else { return }
        content = desired
        presenter.show(desired, staleDate: staleDate(for: desired))
    }

    func markSending(_ action: LockScreenAction) {
        guard var content else { return }
        sending = action
        content.phase = .sending
        content.sending = action
        self.content = content
        presenter.show(content, staleDate: staleDate(for: content))
    }

    func finishSending() { sending = nil }

    func markUnreachable() {
        sending = nil
        guard var content else { return }
        content.phase = .unreachable
        content.sending = nil
        content.paused = true
        self.content = content
        presenter.show(content, staleDate: nil)
    }

    /// iOS cannot run code an hour later, so a paused card ends now and dismisses itself.
    func didEnterBackground() {
        guard presenter.isShowing, let content, content.paused, let pausedSince else { return }
        presenter.end(content, dismissAt: pausedSince.addingTimeInterval(Self.pauseLifetime))
    }

    func end() {
        content = nil
        sending = nil
        pausedSince = nil
        presenter.end(nil, dismissAt: nil)
    }

    /// Playing position drifts by design; only a jump or a visible change needs an update.
    private func needsUpdate(_ desired: Content) -> Bool {
        guard let content else { return true }
        var lhs = content
        var rhs = desired
        lhs.position = 0
        rhs.position = 0
        lhs.anchor = .distantPast
        rhs.anchor = .distantPast
        if lhs != rhs { return true }
        let elapsed = content.paused ? 0 : desired.anchor.timeIntervalSince(content.anchor)
        return abs(content.position + elapsed - desired.position) > 2
    }

    /// After the expected end of the item, the card shows what probably plays next.
    private func staleDate(for content: Content) -> Date? {
        guard content.showsTimer else { return nil }
        return content.anchor.addingTimeInterval(max(0, content.duration - content.position) + 3)
    }
}

/// ActivityKit's handle is safe to use from any thread but is not marked Sendable.
private struct ActivityHandle: @unchecked Sendable {
    let value: Activity<LockScreenAttributes>
}

/// ActivityKit implementation. Updates run in order through one task chain.
@MainActor
final class ActivityKitPresenter: LockScreenPresenter {
    private var activity: Activity<LockScreenAttributes>?
    private var chain: Task<Void, Never>?
    private var endingActivityID: String?
    private let logger = Logger(subsystem: "app.kinrox.remote", category: "lock-screen")

    init() {
        // A card from an earlier launch stays in use; extra ones are removed.
        let existing = Activity<LockScreenAttributes>.activities
        activity =
            existing.first { Self.canUpdate($0) }
            ?? existing.first { $0.activityState == .ended }
        for extra in existing where extra.id != activity?.id {
            let extra = ActivityHandle(value: extra)
            enqueue { await extra.value.end(nil, dismissalPolicy: .immediate) }
        }
    }

    var isShowing: Bool {
        guard let activity, activity.id != endingActivityID else { return false }
        return Self.canUpdate(activity)
    }
    var initialContent: LockScreenAttributes.ContentState? { activity?.content.state }

    private static func canUpdate(_ activity: Activity<LockScreenAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    func show(_ content: LockScreenAttributes.ContentState, staleDate: Date?) {
        let value = ActivityContent(state: content, staleDate: staleDate)
        if let activity, isShowing {
            let handle = ActivityHandle(value: activity)
            enqueue { await handle.value.update(value) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let previous = retainedActivities()
        do {
            let started = try Activity.request(
                attributes: LockScreenAttributes(), content: value, pushType: nil)
            activity = started
            endingActivityID = nil
            for old in previous where old.id != started.id {
                let old = ActivityHandle(value: old)
                enqueue { await old.value.end(nil, dismissalPolicy: .immediate) }
            }
        } catch {
            logger.error("Lock Screen card not started: \(error.localizedDescription)")
        }
    }

    func end(_ content: LockScreenAttributes.ContentState?, dismissAt: Date?) {
        let final = content.map { ActivityContent(state: $0, staleDate: nil) }
        if let dismissAt {
            guard let activity else { return }
            let handle = ActivityHandle(value: activity)
            endingActivityID = activity.id
            // Keep the handle: the ended card remains visible until its dismissal date.
            enqueue { await handle.value.end(final, dismissalPolicy: .after(dismissAt)) }
        } else {
            let retained = retainedActivities()
            activity = nil
            endingActivityID = nil
            for value in retained {
                let handle = ActivityHandle(value: value)
                enqueue { await handle.value.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    private func retainedActivities() -> [Activity<LockScreenAttributes>] {
        var retained = Activity<LockScreenAttributes>.activities
        if let activity, !retained.contains(where: { $0.id == activity.id }) {
            retained.append(activity)
        }
        return retained
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await work()
        }
    }
}
