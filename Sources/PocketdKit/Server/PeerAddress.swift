import Foundation
import FlyingFox

extension HTTPRequest {
    /// The address of whoever actually opened the socket.
    ///
    /// Deliberately NOT `remoteIPAddress`, which FlyingFox defines as
    /// `headers[.xForwardedFor]?.split(separator: ",").first` falling back to
    /// the peer — that is correct behind a reverse proxy you control, and wrong
    /// here. pocketd is a phone listening directly on a LAN with nothing in
    /// front of it, so `X-Forwarded-For` is not a trusted hop, it is a string
    /// the caller chose. Anyone on the network could send
    /// `X-Forwarded-For: 127.0.0.1` and appear in the request log as the phone
    /// itself, or pin their failed pairing attempts on a neighbour's address.
    ///
    /// The peer address comes from the accepted connection and cannot be set by
    /// the caller.
    var peerAddress: String? {
        switch remoteAddress {
        case let .ip4(ip, port: _), let .ip6(ip, port: _):
            return ip
        case .unix, .none:
            return nil
        }
    }

    /// True when the request came from this device rather than over the network.
    /// Based on the socket peer, so it cannot be spoofed by a header.
    var isLoopback: Bool {
        switch remoteAddress {
        case let .ip4(ip, port: _):
            return ip == "127.0.0.1"
        case let .ip6(ip, port: _):
            return ip == "::1"
        case .unix:
            return true
        case .none:
            return false
        }
    }
}

extension HTTPRequest {
    /// The origin, from the accepted connection only.
    var requestOrigin: RequestOrigin {
        switch remoteAddress {
        case let .ip4(ip, port: port), let .ip6(ip, port: port):
            return .network(host: ip, port: port)
        case .unix, .none:
            return .network(host: "unknown", port: 0)
        }
    }
}
