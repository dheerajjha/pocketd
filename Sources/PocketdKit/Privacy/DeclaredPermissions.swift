import Foundation

/// The permissions an app declares, read from its own bundle.
///
/// Driving the list from `Info.plist` rather than from a hardcoded array is
/// what keeps the permissions section true as the app grows — a permission
/// added tomorrow appears without anyone remembering this screen exists. The
/// cost is that the loop is generic, and a generic loop over "every key ending
/// in UsageDescription" will happily emit a second row for a permission the
/// screen already reports under a better name.
public enum DeclaredPermissions {
    /// Usage-description keys that some other row already covers in full.
    ///
    /// `NSLocalNetworkUsageDescription` is the one that bit: local network
    /// access is reported from `NSBonjourServices`, because that key also names
    /// the services being advertised, and the generic loop then rendered a
    /// second row — "LocalNetwork", orange, with the App Store prompt copy
    /// where every other row explains its state. Two rows for one permission,
    /// disagreeing about its name, on the screen whose argument is that its
    /// details are checkable.
    ///
    /// `NSHealthUpdateUsageDescription` is here for a different reason: iOS
    /// terminates an app that links HealthKit without it, and nothing in this
    /// app writes to Health, so a row would claim a permission the app never
    /// exercises. Health read access has its own row.
    public static let keysReportedElsewhere: Set<String> = [
        "NSLocalNetworkUsageDescription",
        "NSHealthUpdateUsageDescription",
    ]

    /// Every usage-description key that deserves a row of its own, in the order
    /// they should be shown.
    public static func rowKeys(in info: [String: Any]) -> [String] {
        info.keys.sorted().filter {
            $0.hasSuffix("UsageDescription") && !keysReportedElsewhere.contains($0)
        }
    }

    /// A readable name for a permission this screen has no special case for.
    ///
    /// Drops a *leading* `NS` rather than every occurrence of it. The blanket
    /// `replacingOccurrences` this replaces is a mine waiting for the first
    /// Apple key with those two letters inside the name, and the failure is
    /// silent: the row still renders, just under a word with a hole in it.
    public static func title(forInfoKey key: String) -> String {
        var name = key
        if name.hasSuffix("UsageDescription") {
            name = String(name.dropLast("UsageDescription".count))
        }
        if name.hasPrefix("NS") {
            name = String(name.dropFirst(2))
        }
        // "PhotoLibraryAdd" is not a phrase. Splitting on the capitals is not
        // perfect either, but it is right far more often than it is wrong, and
        // the raw key is shown as the row's identity anyway.
        return name.splittingCamelCase()
    }
}

private extension String {
    func splittingCamelCase() -> String {
        var out = ""
        var previous: Character?
        for character in self {
            if let previous, character.isUppercase, !previous.isUppercase { out.append(" ") }
            out.append(character)
            previous = character
        }
        return out
    }
}

/// True only for a value that was actually stored as a boolean.
///
/// `case let flag as Bool` is not that test. `NSNumber`'s value-preserving
/// bridge means an integer 1, an integer 0 and a double 1.0 all succeed at
/// `as? Bool`, so a settings screen that promises to list every key "as it is
/// stored" renders a stored `1` as "On" and puts the real value out of reach —
/// verified against a live `UserDefaults`: `set(1,…)` comes back with objCType
/// `q` and `as? Bool == true`.
///
/// The encoding is the only thing that separates them after the fact.
/// CoreFoundation bridges a boolean to `NSNumber` with the ObjC `BOOL`
/// encoding, `"c"`; every integer `UserDefaults` stores encodes as `"q"`. (A
/// literal `Int8` also encodes as `"c"`, which `UserDefaults` has no way to
/// produce — it widens integers to `NSInteger` on the way in.)
public func isStoredAsBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return String(cString: number.objCType) == "c"
}
