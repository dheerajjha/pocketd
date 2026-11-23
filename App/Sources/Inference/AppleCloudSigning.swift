import Foundation

/// Apple's `.available` describes the device, not the app's authorization. A
/// first prompt from an unentitled app is a fatal error, not a catchable refusal.
/// Read the signing receipt generated for *this target*, never a user preference.
/// The App Store can remove the provisioning profile after signing.
enum AppleCloudSigning {
    static let permitsRequests: Bool = {
        guard let file = Bundle.main.url(forResource: "PocketdCloudSigning", withExtension: "plist"),
              let bytes = try? Data(contentsOf: file),
              let receipt = try? PropertyListDecoder().decode(Receipt.self, from: bytes)
        else { return false }
        return receipt.bundleID == Bundle.main.bundleIdentifier && receipt.permitsRequests
    }()

    private struct Receipt: Decodable {
        let bundleID: String
        let permitsRequests: Bool
    }
}
