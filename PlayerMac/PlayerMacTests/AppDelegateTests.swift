import AppKit
import Testing

@testable import Kinrox

@Suite("Application launch")
@MainActor
struct AppDelegateTests {
    @Test("AppKit entries do not create player window or dialog in test host")
    func testHostIgnoresOpenRequests() {
        let delegate = AppDelegate()
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        delegate.application(NSApp, open: [URL(fileURLWithPath: #filePath)])
        delegate.openFile()
        let created = NSApp.windows.filter { !windows.contains(ObjectIdentifier($0)) }
        #expect(created.isEmpty)
        for window in created {
            (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
            window.close()
        }
    }

    @Test("System arguments with path are not opened as video")
    func ignoresOptionValues() {
        #expect(
            AppDelegate.launchURL(arguments: ["Kinrox", "-DiagnosticProfile", #filePath]) == nil)
        #expect(
            AppDelegate.launchURL(arguments: ["Kinrox", "-NSFlag", "YES", "-Log", #filePath]) == nil
        )
    }

    @Test("Explicit path and argument delimiter preserve selected file")
    func acceptsExplicitPath() {
        let path = "/tmp/Movie with spaces.mkv"
        let url = URL(fileURLWithPath: path)
        #expect(AppDelegate.launchURL(arguments: ["Kinrox", path]) == url)
        #expect(AppDelegate.launchURL(arguments: ["Kinrox", "-Log", #filePath, "--", path]) == url)
        #expect(AppDelegate.launchURL(arguments: ["Kinrox", "--"]) == nil)
        #expect(AppDelegate.launchURL(arguments: ["Kinrox"]) == nil)
    }
}
