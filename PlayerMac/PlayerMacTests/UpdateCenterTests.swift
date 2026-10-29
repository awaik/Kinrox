import AppKit
import SwiftUI
import Testing

@testable import Kinrox

@MainActor
private final class FakeUpdateDriver: UpdateDriver {
    var checks = 0
    func checkForUpdates() { checks += 1 }
}

@Suite("Update reminders")
@MainActor
struct UpdateCenterTests {
    private let notes = URL(string: "https://github.com/awaik/Kinrox/releases/tag/v0.4.0")!

    @Test("Banner appears for a scheduled update; × hides it but keeps the menu hint")
    func remindAndHide() {
        let center = UpdateCenter(currentVersion: "0.3.0")
        #expect(!center.showsReminder)
        center.remind(AvailableUpdate(version: "0.4.0", releaseNotesURL: notes))
        #expect(center.showsReminder)
        center.hide()
        #expect(!center.showsReminder)
        #expect(center.available?.version == "0.4.0")
        center.remind(AvailableUpdate(version: "0.4.0", releaseNotesURL: notes))
        #expect(center.showsReminder)
    }

    @Test("Compact pill never covers playing video")
    func pillOnlyWhenPaused() {
        let center = UpdateCenter(currentVersion: "0.3.0")
        #expect(!center.showsPill(paused: true))
        center.remind(AvailableUpdate(version: "0.4.0", releaseNotesURL: nil))
        #expect(center.showsPill(paused: true))
        #expect(!center.showsPill(paused: false))
        center.hide()
        #expect(!center.showsPill(paused: true))
    }

    @Test("Update hands over to Sparkle; its session end clears the reminder")
    func installHandsOver() {
        let driver = FakeUpdateDriver()
        let center = UpdateCenter(currentVersion: "0.3.0")
        #expect(!center.isEnabled)
        center.attach(driver)
        #expect(center.isEnabled)
        center.remind(AvailableUpdate(version: "0.4.0", releaseNotesURL: nil))
        center.install()
        #expect(driver.checks == 1)
        #expect(!center.showsReminder)
        center.finish()
        #expect(center.available == nil)
        center.checkForUpdates()
        #expect(driver.checks == 2)
    }

    @Test("What's New opens the release page only when the feed provides one")
    func releaseNotes() {
        var opened: [URL] = []
        let center = UpdateCenter(currentVersion: "0.3.0") { opened.append($0) }
        center.showReleaseNotes()
        center.remind(AvailableUpdate(version: "0.4.0", releaseNotesURL: nil))
        center.showReleaseNotes()
        #expect(opened.isEmpty)
        center.remind(AvailableUpdate(version: "0.4.0", releaseNotesURL: notes))
        center.showReleaseNotes()
        #expect(opened == [notes])
    }

    @Test("Updater needs an HTTPS feed and an EdDSA key; local builds make no requests")
    func configuration() {
        let feed = "https://awaik.github.io/Kinrox/appcast.xml"
        let key = String(repeating: "A", count: 43) + "="
        #expect(SparkleUpdater.isConfigured(info: ["SUFeedURL": feed, "SUPublicEDKey": key]))
        #expect(!SparkleUpdater.isConfigured(info: ["SUFeedURL": feed, "SUPublicEDKey": " "]))
        #expect(!SparkleUpdater.isConfigured(info: ["SUFeedURL": feed]))
        #expect(
            !SparkleUpdater.isConfigured(info: [
                "SUFeedURL": "http://awaik.github.io/Kinrox/appcast.xml", "SUPublicEDKey": key,
            ]))
        #expect(
            !SparkleUpdater.isConfigured(info: ["SUFeedURL": "https://", "SUPublicEDKey": key]))
    }

    @Test("Release smoke checks leave the updater uninitialized")
    func smokeCheck() {
        let center = UpdateCenter(currentVersion: "0.3.0")
        let updater = SparkleUpdater(
            center: center, environment: ["KINROX_RELEASE_SMOKE_TEST": "1"])
        #expect(updater == nil)
        #expect(!center.isEnabled)
    }

    @Test("Player Info.plist points to the landing appcast without system profiling")
    func infoPlist() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://awaik.github.io/Kinrox/appcast.xml")
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(info["SUScheduledCheckInterval"] as? Int == 86400)
        // xcconfig treats `//` as a comment; a truncated key would reject every update.
        let key = info["SUPublicEDKey"] as? String ?? ""
        #expect(key.isEmpty || key.wholeMatch(of: /[A-Za-z0-9+\/]{43}=/) != nil)
    }
}

@Suite("Update banner layout")
@MainActor
struct UpdateBannerLayoutTests {
    /// Renders both reminders; set TEST_RUNNER_KINROX_SNAPSHOT_DIR to keep PNGs for review.
    @Test("Banner and pill keep Figma page 05 proportions")
    func renders() throws {
        let center = UpdateCenter(currentVersion: "0.3.0")
        let update = AvailableUpdate(
            version: "0.4.0", releaseNotesURL: URL(string: "https://example.com/notes"))
        let banner = ImageRenderer(
            content: UpdateBanner(center: center, update: update).frame(width: 1032)
                .padding(40).background(Palette.base))
        banner.scale = 2
        let pill = ImageRenderer(
            content: UpdatePill(center: center, update: update).padding(40).background(Palette.base)
        )
        pill.scale = 2
        let bannerImage = try #require(banner.nsImage)
        let pillImage = try #require(pill.nsImage)
        // Figma: banner 1032 × 90, pill 340 × 42 (40 pt padding on each side here).
        #expect(abs(bannerImage.size.height - 80 - 90) <= 6)
        #expect(abs(pillImage.size.height - 80 - 42) <= 4)
        #expect(pillImage.size.width - 80 < 420)
        if let directory = ProcessInfo.processInfo.environment["KINROX_SNAPSHOT_DIR"] {
            for (name, image) in [("update-banner", banner.cgImage), ("update-pill", pill.cgImage)]
            {
                let image = try #require(image)
                let data = try #require(
                    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
    }
}
