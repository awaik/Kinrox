import Foundation

struct SavedMac: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
}

/// Non-sensitive settings only. Token never enters UserDefaults.
@MainActor
final class RemotePreferences {
    private let defaults: UserDefaults
    let deviceId: UUID
    var selected: SavedMac? {
        get {
            defaults.data(forKey: "remote.selectedMac").flatMap {
                try? JSONDecoder().decode(SavedMac.self, from: $0)
            }
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "remote.selectedMac") }
    }
    // Auth rejection does not delete token: unauthenticated response lacks authority.
    var rejectedServers: Set<UUID> {
        get {
            Set(
                (defaults.stringArray(forKey: "remote.rejectedServers") ?? []).compactMap(UUID.init)
            )
        }
        set { defaults.set(newValue.map(\.uuidString), forKey: "remote.rejectedServers") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        deviceId = defaults.string(forKey: "remote.deviceId").flatMap(UUID.init) ?? UUID()
        defaults.set(deviceId.uuidString, forKey: "remote.deviceId")
    }
    func forget(_ id: UUID) {
        if selected?.id == id { selected = nil }
        rejectedServers.remove(id)
    }
}
