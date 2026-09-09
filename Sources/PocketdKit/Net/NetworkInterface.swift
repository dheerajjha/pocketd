import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finds the address a laptop on the same network should point at.
///
/// The UI needs this because "the server is running" is useless information
/// without the URL to paste into LM Studio or `curl`. `en0` is Wi-Fi on iOS;
/// `en1`..`en4` cover wired adapters and Mac targets.
public enum NetworkInterface {
    public static func localIPv4Address() -> String? {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        let preferred = ["en0", "en1", "en2", "en3", "en4"]
        var found: [String: String] = [:]

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            if result == 0 {
                found[name] = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        for name in preferred where found[name] != nil {
            return found[name]
        }
        return found.values.sorted().first
        #else
        return nil
        #endif
    }
}
