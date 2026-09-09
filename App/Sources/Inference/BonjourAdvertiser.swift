import Foundation
import PocketdKit

/// Publishes the server on the local network so nothing has to type an address.
///
/// This is the honest fix for the DHCP problem in the README: a phone's IP moves,
/// and a URL someone wrote down stops working. A Bonjour name does not move.
///
/// `NetService` rather than `NWListener`, deliberately: NWListener advertises
/// only a socket it owns, and ours belongs to FlyingFox. NetService can publish
/// a port that something else is listening on, which is exactly the case here.
/// It is soft-deprecated (`API_TO_BE_DEPRECATED`) and still the only API that
/// does this; switching would mean replacing the HTTP server's socket layer.
final class BonjourAdvertiser: NSObject, @unchecked Sendable {
    private var services: [NetService] = []

    /// Advertised under two types on purpose. `_pocketd._tcp` is ours, for
    /// anything that wants to find specifically this; `_ollama._tcp` is the
    /// name Ollama-aware tools already browse for, and being discoverable by
    /// something the user already has beats being discoverable by nothing.
    static let serviceTypes = ["_pocketd._tcp.", "_ollama._tcp."]

    func start(port: UInt16, name: String, model: String?, requiresAuth: Bool) {
        stop()
        // TXT records carry what a browser needs to decide whether to bother
        // connecting, without a round trip.
        var txt: [String: Data] = [
            "version": Data(PocketdKit.version.utf8),
            "auth": Data((requiresAuth ? "required" : "none").utf8),
            "api": Data("openai,ollama".utf8),
        ]
        if let model { txt["model"] = Data(model.utf8) }

        services = Self.serviceTypes.map { type in
            let service = NetService(domain: "local.", type: type, name: name, port: Int32(port))
            service.delegate = self
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            service.publish()
            return service
        }
    }

    func stop() {
        for service in services { service.stop() }
        services = []
    }

    deinit { stop() }
}

extension BonjourAdvertiser: NetServiceDelegate {
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        // The commonest cause is Local Network permission not being granted,
        // which is silent otherwise — the socket accepts nothing and the app
        // looks broken. Surfaced rather than swallowed.
        NSLog("pocketd: Bonjour publish failed for \(sender.type): \(errorDict)")
    }
}
