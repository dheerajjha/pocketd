import Foundation

/// Turns the errors this app actually throws into the bounded reasons the
/// taxonomy allows.
///
/// In the package rather than the app target on purpose: every function here
/// is pure, and the app target has no test bundle. Putting it here is the
/// difference between this logic being tested and being mirrored by a copy in
/// a test file that can silently drift from it — which this repo already does
/// once, for the reasoning-block splitter, and says so in a comment.
///
/// The whole point of this file is that it is the ONLY bridge between an error
/// and something transmittable, so there is one place to check that no error's
/// own text can reach the wire. `LocalizedError.errorDescription` and the
/// message inside `ModelTransfer.State.failed` are both readable strings meant
/// for a human on this device, and a `URLError`'s `userInfo` carries the signed
/// CDN URL and the whole resume blob — that has already been printed to a
/// screen in this app once. None of it belongs in an analytics property.
public enum AnalyticsMapping {

    public static func downloadReason(for error: any Error) -> DownloadFailureReason {
        if let store = error as? ModelStoreError {
            switch store {
            case .insufficientMemory: return .insufficientMemory
            case .insufficientDisk: return .insufficientDisk
            case .httpStatus: return .httpError
            case .incompleteDownload: return .incompleteBytes
            case .notInstalled: return .other
            }
        }
        if let interruption = DownloadInterruption.from(error) {
            switch interruption {
            case .offline: return .offline
            case .connectionLost: return .timedOut
            }
        }
        switch (error as NSError).code {
        case NSURLErrorNotConnectedToInternet: return .offline
        case NSURLErrorTimedOut: return .timedOut
        default: return .other
        }
    }

    public static func loadReason(for error: any Error) -> LoadFailureReason {
        if let store = error as? ModelStoreError {
            switch store {
            case .insufficientMemory: return .outOfMemory
            case .notInstalled: return .fileMissing
            default: return .other
            }
        }
        // llama.cpp's own failures arrive as opaque errors whose text is not
        // ours to forward. The interesting case — the device ran out of memory
        // — usually presents as the process being killed rather than as a
        // throw, so `.other` here is honest rather than lazy: what we can see
        // is that it did not load.
        return .other
    }

    /// A bucket, not a measurement.
    ///
    /// Physical RAM rounded to the nearest shipped configuration. Exact byte
    /// counts would narrow a device down further than the question needs —
    /// "do 4 GB phones fail to load 3B models" is answered by the bucket, and
    /// the bucket cannot help identify anyone.
    public static func ramClass(bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        switch gigabytes {
        case ..<3.5: return "3gb"
        case ..<5: return "4gb"
        case ..<7: return "6gb"
        case ..<9: return "8gb"
        case ..<13: return "12gb"
        default: return "16gb_plus"
        }
    }

    /// Whether a logged request came from somewhere other than this phone.
    ///
    /// The phone's own /chat page is a network client at the route layer — a
    /// deliberate decision, since privileging it would be a security hole — so
    /// without this check the one event that answers "is anyone using this as
    /// a server" would count the phone talking to itself.
    public static func isExternal(clientAddress: String?) -> Bool {
        guard let address = clientAddress?.trimmingCharacters(in: .whitespaces),
              !address.isEmpty else { return false }
        let loopback = ["127.0.0.1", "::1", "localhost", "0:0:0:0:0:0:0:1"]
        return !loopback.contains(address.lowercased())
    }

    /// Which API surface was spoken, from the path we served rather than from
    /// anything the client claimed about itself.
    public static func dialect(path: String) -> ClientDialect? {
        if path.hasPrefix("/v1/") { return .openai }
        if path.hasPrefix("/api/") { return .ollama }
        return nil
    }
}


/// When leaving the intro counts as having seen the analytics decision.
///
/// A rule rather than a comparison written inline in a view, because it is the
/// line between "informed" and "assumed" and a bare `step >= 2` in a layout
/// file is not somewhere that line survives a screen being reordered. If
/// someone inserts a screen before the consent one, this constant is what they
/// have to change, and the test is what tells them they forgot.
public enum OnboardingConsentRule {
    /// Zero-based index of the screen carrying the toggle.
    public static let consentScreenIndex = 2

    /// Whether someone leaving from `step` was shown the toggle first.
    ///
    /// Leaving from the consent screen itself counts: it is on screen, above
    /// the fold, reading ON. Leaving from before it does not — they never saw
    /// the sentence, and a default nobody was shown is not a decision.
    public static func decisionWasSeen(leavingFromStep step: Int) -> Bool {
        step >= consentScreenIndex
    }
}
