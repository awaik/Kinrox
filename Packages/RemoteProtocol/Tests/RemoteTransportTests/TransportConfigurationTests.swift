import RemoteTransport
import Testing

@Test("Bonjour uses agreed service type and version")
func initialTransportConfiguration() {
    #expect(TransportConfiguration.serviceType == "_kinrox._tcp")
    #expect(TransportConfiguration.protocolVersion == 1)
}
