import AppKit
import Observation

/// Newer player version found by a scheduled check.
struct AvailableUpdate: Equatable, Sendable {
    let version: String
    let releaseNotesURL: URL?
}

/// Installs updates; Sparkle in the app, a fake in tests.
@MainActor
protocol UpdateDriver: AnyObject {
    /// Shows the pending update, or checks for one, in Sparkle's standard window.
    func checkForUpdates()
}

/// Update reminder state for the welcome banner, paused-player pill, and app menu.
/// Kinrox shows only "update available"; download and install stay in Sparkle's window
/// (owner decision 2026-10-29, Figma page 05).
@MainActor @Observable
final class UpdateCenter {
    let currentVersion: String
    private(set) var available: AvailableUpdate?
    /// × hides the reminder until Sparkle's next scheduled check; the menu keeps the hint.
    private(set) var isHidden = false
    private(set) var isEnabled = false
    var canCheckForUpdates = false
    @ObservationIgnored private weak var driver: UpdateDriver?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void

    init(
        currentVersion: String = UpdateCenter.bundleVersion,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.currentVersion = currentVersion
        self.openURL = openURL
    }

    nonisolated static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var showsReminder: Bool { available != nil && !isHidden }

    /// The compact pill never covers playing video.
    func showsPill(paused: Bool) -> Bool { showsReminder && paused }

    func attach(_ driver: UpdateDriver) {
        self.driver = driver
        isEnabled = true
    }

    func remind(_ update: AvailableUpdate) {
        available = update
        isHidden = false
    }

    func hide() { isHidden = true }

    /// Sparkle took over (user opened its window) or the update session ended.
    func finish() {
        available = nil
        isHidden = false
    }

    func install() {
        isHidden = true
        driver?.checkForUpdates()
    }

    func checkForUpdates() { driver?.checkForUpdates() }

    func showReleaseNotes() {
        if let url = available?.releaseNotesURL { openURL(url) }
    }
}
