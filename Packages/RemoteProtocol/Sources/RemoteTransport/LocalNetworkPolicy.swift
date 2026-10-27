import Darwin
import Foundation
import Network

/// Not a list of private ranges: address must belong to an active local subnet.
/// acceptLocalOnly additionally restricts incoming connections at the system level.
enum LocalNetworkPolicy {
    struct Subnet: Sendable {
        let address: Data
        let mask: Data
        let interface: String

        func contains(_ candidate: Data) -> Bool {
            guard address.count == candidate.count, mask.count == candidate.count,
                mask.contains(where: { $0 != 0 })
            else { return false }
            return zip(zip(address, candidate), mask).allSatisfy { pair, mask in
                pair.0 & mask == pair.1 & mask
            }
        }
    }

    static func permits(_ endpoint: NWEndpoint?, subnets: [Subnet] = activeSubnets()) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return permitsIPv4(address, subnets: subnets)
        case .ipv6(let address):
            let bytes = address.rawValue
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255,
                let mapped = IPv4Address(Data(bytes.suffix(4)))
            {
                return permitsIPv4(mapped, subnets: subnets)
            }
            guard !address.isAny, !address.isMulticast else { return false }
            if address.isLoopback { return true }
            return subnets.contains {
                $0.contains(bytes)
                    && (!address.isLinkLocal || address.interface?.name == $0.interface)
            }
        case .name: return false  // Names are checked only after resolution to an address.
        @unknown default: return false
        }
    }

    private static func permitsIPv4(_ address: IPv4Address, subnets: [Subnet]) -> Bool {
        let bytes = address.rawValue
        // IPv4Address comparison respects scope; special ranges are specified via bytes.
        guard bytes.contains(where: { $0 != 0 }), bytes.contains(where: { $0 != 255 }),
            !address.isMulticast
        else { return false }
        if bytes.first == 127 { return true }
        return subnets.contains { subnet in
            guard subnet.contains(address.rawValue) else { return false }
            // Reject directed broadcast of the subnet (none for /31 and /32).
            let hostBits = subnet.mask.reduce(0) { $0 + (8 - $1.nonzeroBitCount) }
            return hostBits <= 1
                || !zip(address.rawValue, subnet.mask).allSatisfy { $0 | $1 == 255 }
        }
    }

    static func activeSubnets() -> [Subnet] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var result: [Subnet] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            let entry = pointer.pointee
            current = entry.ifa_next
            guard entry.ifa_flags & UInt32(IFF_UP) != 0,
                entry.ifa_flags & UInt32(IFF_POINTOPOINT) == 0,
                let address = entry.ifa_addr, let mask = entry.ifa_netmask,
                let addressBytes = bytes(address), let maskBytes = bytes(mask),
                addressBytes.contains(where: { $0 != 0 })
            else { continue }
            result.append(
                .init(
                    address: addressBytes, mask: maskBytes,
                    interface: String(cString: entry.ifa_name)))
        }
        return result
    }

    private static func bytes(_ address: UnsafePointer<sockaddr>) -> Data? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var value = $0.pointee.sin_addr
                return withUnsafeBytes(of: &value) { Data($0) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var value = $0.pointee.sin6_addr
                return withUnsafeBytes(of: &value) { Data($0) }
            }
        default: return nil
        }
    }
}
