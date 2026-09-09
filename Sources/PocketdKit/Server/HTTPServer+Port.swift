import Foundation
import FlyingFox
import FlyingSocks

extension HTTPServer {
    /// The port the listener actually bound to, which differs from the requested
    /// port whenever 0 was requested.
    func resolvedPort() -> UInt16? {
        switch listeningAddress {
        case let .ip4(_, port: port), let .ip6(_, port: port):
            return port
        case .unix, .none:
            return nil
        }
    }
}
