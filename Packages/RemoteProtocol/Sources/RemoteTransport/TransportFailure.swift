import Network
import RemoteProtocol

public enum TransportFailure: Error, Sendable, Equatable {
    case network(NWError)
    case protocolFailure(ProtocolError)
    case closed, notConnected, timeout, nonLocalEndpoint
    case invalidMessage, messageTooLarge, backpressure, invalidService, storageFailure
}
