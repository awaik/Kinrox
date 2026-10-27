import Network
import RemoteProtocol

/// v1 parameters: one binary WebSocket message per application frame.
public enum TransportConfiguration {
    public static let serviceType = "_kinrox._tcp"
    public static let domain = "local."
    public static let protocolVersion = Version.current
    public static let maximumClients = 4
    public static let pingInterval: Duration = .seconds(5)
    public static let clientTimeout: Duration = .seconds(15)
    public static let serverTimeout: Duration = .seconds(20)
    public static let handshakeTimeout: Duration = .seconds(15)

    static func parameters(listener: Bool = false) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        parameters.acceptLocalOnly = listener
        parameters.preferNoProxies = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = Codec.maxMessageBytes
        // Bonjour service endpoint is not an HTTP Upgrade URL. Both sides
        // immediately use WS framing followed by mandatory CryptoKit handshake.
        webSocket.skipHandshake = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }
}
