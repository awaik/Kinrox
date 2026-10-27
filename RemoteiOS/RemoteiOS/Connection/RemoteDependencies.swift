import Foundation
import Network
import RemoteProtocol
import RemoteTransport

@MainActor
protocol RemoteConnection: AnyObject {
    var onStateChange: ((TransportClient.State) -> Void)? { get set }
    var onEvent: ((TransportClient.Event) -> Void)? { get set }
    func start()
    func submitPIN(_ pin: String) async throws
    func send(_ message: Message) async throws
    func close(_ failure: TransportFailure)
}
extension TransportClient: RemoteConnection {}

typealias RemoteConnectionFactory =
    @MainActor (
        DiscoveredServer, UUID, ClientHandshake.Mode, @escaping (Data) throws -> Void
    ) throws -> any RemoteConnection

@MainActor
protocol RemoteDiscovery: AnyObject {
    var servers: [DiscoveredServer] { get }
    var state: BonjourBrowser.State { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}
extension BonjourBrowser: RemoteDiscovery {}

enum RemoteNetworkState: Equatable { case unknown, available, unavailable, denied }

/// Monitors local interface readiness only; Bonjour absence does not equal failure.
@MainActor
final class RemoteNetworkMonitor {
    private let monitor = NWPathMonitor(prohibitedInterfaceTypes: [.cellular])
    init(changed: @escaping @MainActor (RemoteNetworkState) -> Void) {
        monitor.pathUpdateHandler = { path in
            MainActor.assumeIsolated {
                if path.unsatisfiedReason == .localNetworkDenied {
                    changed(.denied)
                } else {
                    changed(path.status == .satisfied ? .available : .unavailable)
                }
            }
        }
        monitor.start(queue: .main)
    }
    func stop() { monitor.cancel() }
    deinit { monitor.cancel() }
}

enum RemoteDiscoveryStatus: Equatable {
    case searching, hints, ready, noNetwork, permissionDenied, transportError
    static func resolve(
        browser: BonjourBrowser.State, network: RemoteNetworkState,
        hasServers: Bool, elapsed: Bool
    ) -> Self {
        if network == .denied { return .permissionDenied }
        switch browser {
        case .waiting(.dns(-65570)), .failed(.dns(-65570)): return .permissionDenied
        default: break
        }
        if network == .unavailable { return .noNetwork }
        switch browser {
        case .waiting, .failed: return .transportError
        default: return hasServers ? .ready : elapsed ? .hints : .searching
        }
    }
}

extension TransportFailure {
    /// Error class only, without addresses, server text, or secrets.
    var diagnosticCode: String {
        switch self {
        case .network: "network"
        case .protocolFailure(let error): "protocol.\(error.code.rawValue)"
        case .closed: "closed"
        case .notConnected: "notConnected"
        case .timeout: "timeout"
        case .nonLocalEndpoint: "nonLocalEndpoint"
        case .invalidMessage: "invalidMessage"
        case .messageTooLarge: "messageTooLarge"
        case .backpressure: "backpressure"
        case .invalidService: "invalidService"
        case .storageFailure: "storageFailure"
        }
    }
}
