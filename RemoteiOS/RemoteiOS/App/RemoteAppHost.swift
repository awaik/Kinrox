import Foundation
import Observation

/// Owns the remote model for the whole process. A Lock Screen button can launch the app
/// in the background, before any window exists, so the model cannot live in a view.
@MainActor @Observable
final class RemoteAppHost {
    static let shared = RemoteAppHost()

    private(set) var store: RemoteAppModel

    private init() {
        store = Self.makeStore(demo: ProcessInfo.processInfo.arguments.contains("-KinroxDemo"))
        LockScreenCommands.handler = { action in
            await RemoteAppHost.shared.store.performLockScreen(action)
        }
    }

    func switchMode() {
        let demo = !store.isDemo
        store.stop()
        store = Self.makeStore(demo: demo)
        store.start()
    }

    private static func makeStore(demo: Bool) -> RemoteAppModel {
        let testing = NSClassFromString("XCTestCase") != nil
        return RemoteAppModel(
            isDemo: demo,
            lockScreen: testing
                ? nil : LockScreenActivityController(presenter: ActivityKitPresenter()))
    }
}
