import Foundation
import Observation

/// What the app is allowed to know about the person using it.
///
/// One string. That is not a placeholder for a richer profile later — it is the
/// whole thing, and the smallness is the product: an assistant that greets you
/// by name needs a name, and it needs nothing else. There is no account, no
/// identifier, no birthday, no photo, and adding any of them would need an
/// answer to "why does a local assistant need that" which does not exist.
///
/// Stored in `UserDefaults` rather than in the keychain or a file, because it
/// is a preference rather than a secret and because the Privacy screen lists
/// the defaults domain key by key — a name in a file nobody enumerates is a
/// name this app's own promise cannot account for.
///
/// Its own object rather than three properties on `AppModel` so that a view
/// that only greets somebody observes one small thing and does not redraw every
/// time a download reports a byte count.
@MainActor
@Observable
final class Profile {
    /// The key, spelled once. Named in the `pd.` namespace rather than the
    /// older `pocketd.` one because everything v2 writes uses it.
    static let nameKey = "pd.profile.name"

    private let defaults: UserDefaults

    /// What to call them. Empty means "they have not said", which is a
    /// different state from "they said nothing" only in that the app never
    /// asks twice.
    var name: String {
        didSet {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Removed rather than stored as "", so that the Privacy screen's
            // list of stored keys does not carry an entry for a name nobody
            // gave. An empty string on that screen reads as data held.
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Self.nameKey)
            } else {
                defaults.set(trimmed, forKey: Self.nameKey)
            }
            if trimmed != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                onNameChange?()
            }
        }
    }

    /// Told when the name changes, so the brief that greets by it can be
    /// rewritten at once rather than at the next refresh. Set by `AppModel`.
    @ObservationIgnored var onNameChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.name = defaults.string(forKey: Self.nameKey) ?? ""
    }

    /// The letter in the avatar circle.
    ///
    /// The first letter of the first word, which is right for "Dheeraj" and for
    /// "de Souza" alike. `first` on the trimmed string rather than `prefix(1)`
    /// on the raw one, so a leading space does not produce a blank circle.
    ///
    /// Falls back to Pocketd's own initial rather than to a person symbol: a
    /// grey silhouette where a name should be is the universal sign of an
    /// account that has not been set up, and there is no account here.
    var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "P" }
        return String(first).uppercased()
    }

    /// The name to greet with, or nothing.
    ///
    /// Optional on purpose. "Good morning," with a trailing comma and nothing
    /// after it is the shape of every app that stored an empty string and
    /// interpolated it anyway; a caller holding an optional has to write the
    /// other sentence.
    var greetingName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
