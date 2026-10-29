import Foundation
import Sparkle

/// Sparkle 2 with gentle reminders: scheduled updates appear in the Kinrox banner,
/// while download, verification, and installation stay in Sparkle's standard windows.
/// The only request is the HTTPS appcast; system profiling is off in Info.plist.
@MainActor
final class SparkleUpdater: NSObject {
    private let center: UpdateCenter
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    #if DEBUG
        /// Local verification only: serve a test appcast and sign it with a test key.
        private let debugFeedURL = ProcessInfo.processInfo.environment["KINROX_UPDATE_FEED_URL"]
    #endif

    /// Returns nil without a feed and EdDSA key, so local builds make no requests.
    init?(
        center: UpdateCenter, bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // Release smoke checks still load/link Sparkle, but must not start its
        // scheduler or mutate the installed player's update preferences.
        guard environment["KINROX_RELEASE_SMOKE_TEST"] != "1" else { return nil }
        guard Self.isConfigured(info: bundle.infoDictionary ?? [:]) else { return nil }
        self.center = center
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.center.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        center.attach(self)
        controller.startUpdater()
        #if DEBUG
            if debugFeedURL != nil { controller.updater.checkForUpdatesInBackground() }
        #endif
    }

    nonisolated static func isConfigured(info: [String: Any]) -> Bool {
        let key = (info["SUPublicEDKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let feed = URL(string: info["SUFeedURL"] as? String ?? "")
        return !key.isEmpty && feed?.scheme == "https" && feed?.host() != nil
    }
}

extension SparkleUpdater: UpdateDriver {
    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
            return debugFeedURL
        #else
            return nil
        #endif
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
            // Development builds share defaults with releases: no scheduled checks
            // against the public feed. Manual checks remain available.
            if updateCheck == .updatesInBackground, debugFeedURL == nil {
                throw CocoaError(.userCancelled)
            }
        #endif
    }
}

extension SparkleUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled updates always go to the Kinrox banner instead of Sparkle's alert.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        center.remind(
            AvailableUpdate(
                version: update.displayVersionString,
                releaseNotesURL: update.fullReleaseNotesURL ?? update.releaseNotesURL))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        center.finish()
    }

    func standardUserDriverWillFinishUpdateSession() { center.finish() }
}
