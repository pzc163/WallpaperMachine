import Darwin
import Foundation

/// Explicit local-service consent permits only loopback, RFC1918, IPv6 local ranges and mDNS.
/// Never resolve a public hostname or accept alternate integer/octal IPv4 spellings as a shortcut.
enum LLMLocalEndpoint {
    static func safeEncoding(_ components: URLComponents) -> Bool {
        guard let encoded = components.percentEncodedHost, let decoded = components.host else { return false }
        if !encoded.contains("%") { return true }
        let host = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return host.contains("%") && allows(host) && encoded.lowercased() == decoded.lowercased().replacingOccurrences(of: "%", with: "%25")
    }
    static func allows(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) {
            let octets = pieces.compactMap { UInt8($0) }
            guard octets.count == 4, zip(pieces, octets).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
            return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }
        if host.contains(":"), !host.contains(".") {
            let scoped = host.split(separator: "%", omittingEmptySubsequences: false)
            guard (1...2).contains(scoped.count) else { return false }
            if scoped.count == 2 {
                guard (1...16).contains(scoped[1].utf8.count), scoped[1].utf8.allSatisfy({
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
                }) else { return false }
            }
            var address = in6_addr()
            guard String(scoped[0]).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            return (scoped.count == 1 && bytes[0] & 0xfe == 0xfc) || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        guard host.utf8.count <= 253, pieces.count >= 2, pieces.last == "local" else { return false }
        return pieces.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
