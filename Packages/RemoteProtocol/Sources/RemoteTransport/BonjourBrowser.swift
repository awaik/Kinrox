import Foundation
import Network

@MainActor public final class BonjourBrowser {
    public enum State: Equatable {
        case stopped, searching, ready
        case waiting(NWError)
        case failed(NWError)
    }
    public private(set) var state = State.stopped
    public private(set) var servers: [DiscoveredServer] = []
    public var onChange: (() -> Void)?
    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: TransportConfiguration.serviceType,
                domain: TransportConfiguration.domain), using: parameters)
        self.browser = browser
        state = .searching
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.browserStateChanged(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.update(
                    results.compactMap { result in
                        guard case .bonjour(let record) = result.metadata else { return nil }
                        return DiscoveredServer(endpoint: result.endpoint, record: record)
                    })
            }
        }
        browser.start(queue: .main)
        onChange?()
    }

    func browserStateChanged(_ state: NWBrowser.State) {
        guard browser != nil else { return }
        switch state {
        case .ready: self.state = .ready
        case .waiting(let error):
            self.state = .waiting(error)
            self.markUnavailable()
        case .failed(let error):
            let previous = browser
            browser = nil
            previous?.cancel()
            self.state = .failed(error)
            self.markUnavailable()
        case .cancelled:
            browser = nil
            self.state = .stopped
            self.markUnavailable()
        default: break
        }
        self.onChange?()
    }

    public func stop() {
        let previous = browser
        browser = nil
        previous?.cancel()
        state = .stopped
        markUnavailable()
        onChange?()
    }

    func update(_ available: [DiscoveredServer]) {
        var byId = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in byId.keys { byId[id]?.isAvailable = false }
        for item in available.sorted(by: {
            $0.endpoint.debugDescription < $1.endpoint.debugDescription
        }) {
            byId[item.id] = item
        }
        servers = byId.values.sorted {
            if $0.name == $1.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        onChange?()
    }

    private func markUnavailable() {
        for index in servers.indices { servers[index].isAvailable = false }
    }

    deinit { browser?.cancel() }
}
