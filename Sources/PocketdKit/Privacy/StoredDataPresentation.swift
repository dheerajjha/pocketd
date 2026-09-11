import Foundation

// How the data inspector renders what it found.
//
// These live beside the inventory rather than in the view, and for one reason:
// each is a claim the screen makes about this device. A claim assembled inline
// in a `body` is a claim nobody can write a test against, and the screen's whole
// value is that its details are checkable — so the details are built where they
// can be checked.

// MARK: - Identifiers, printed as they are stored

/// The characters a path or a reverse-DNS key is naturally read in pieces at.
private let identifierBreakCharacters: Set<Character> = ["/", ".", "_", "-", ":"]

/// Invisible, uncopied, and not a character the reader can mistake for content.
private let zeroWidthSpace: Character = "\u{200B}"

/// A path or preference key with break opportunities, so the layout never has
/// to invent one.
///
/// TextKit hyphenates any token too long for its line, which on this screen
/// prints a string that is not the one on disk: every iOS container holds
/// `.com.apple.mobile_container_manager.metadata.plist`, and it renders as
/// `…metadata.-plist` at the default text size. At accessibility sizes five of
/// the six preference keys grow a hyphen too, under a heading promising "every
/// key in this app's preferences file, listed as it is stored". Shrinking the
/// text does not help — `minimumScaleFactor` hyphenates once it hits its floor.
public func breakableIdentifier(_ text: String) -> String {
    var out = String()
    out.reserveCapacity(text.count * 2)
    for character in text {
        out.append(character)
        if identifierBreakCharacters.contains(character) { out.append(zeroWidthSpace) }
    }
    return out
}

/// What `breakableIdentifier` inserted, removed again — so a test can prove the
/// rendered token is still the stored one.
public func strippingBreakOpportunities(_ text: String) -> String {
    String(text.filter { $0 != zeroWidthSpace })
}

// MARK: - Preference values, as they are stored

/// One preferences entry, described without lying about its type.
///
/// Every arm is a string, so nothing can fall through to nothing, and the
/// fallback names the type it could not describe rather than the box it arrived
/// in: `value` is an `Any?`, and `type(of:)` on that reports `Optional<Any>` for
/// every unhandled type in the file. `pocketd.pairedAt` is a `Date` and hit it
/// on every paired device, so the one key that says when this phone was paired
/// was the one key this screen could not state.
public func storedValueSummary(_ value: Any?, forKey key: String) -> String {
    // `case let flag as Bool` cannot lead here. NSNumber's value-preserving
    // bridge makes an integer 1 and a double 1.0 both succeed at `as? Bool`,
    // so a future `threads: 1` would render as "On" on the one screen that
    // promises to show every key as it is stored.
    if let value, isStoredAsBoolean(value) {
        return (value as? Bool) == true ? "On" : "Off"
    }
    return switch value {
    case let number as NSNumber: number.stringValue
    case let text as String: text.count > 60 ? String(text.prefix(60)) + "…" : text
    case let date as Date: date.formatted(date: .abbreviated, time: .shortened)
    case let data as Data:
        // The one entry that holds a secret. Named rather than dumped: a hex
        // blob would be honest and useless, and printing the JSON would put a
        // working credential on screen.
        key.hasSuffix("configuration")
            ? "Port, binding, sampling defaults and the API key — \(formattedByteCount(Int64(data.count)))"
            : "\(formattedByteCount(Int64(data.count))) of data"
    case let list as [Any]: "\(list.count) items"
    case .none: "Empty"
    default: value.map { String(describing: type(of: $0)) } ?? "Empty"
    }
}

// MARK: - Permissions, as VoiceOver hears them

/// Everything one permission row says, in one string.
///
/// The note is in it because the note is the row. `.accessibilityElement(children: .combine)`
/// derives a label from the children and a following `.accessibilityLabel`
/// replaces that derived label outright, so a row that overrode it with title
/// and state alone left a VoiceOver user hearing "Health: Not reported by iOS"
/// and no way to reach the sentence explaining that iOS never reports read
/// authorization for Health at all. "Not reported" with the reason removed is
/// exactly the dodge the note exists to prevent.
public func permissionAnnouncement(title: String, state: String, note: String?) -> String {
    ["\(title): \(state)", note].compactMap(\.self).joined(separator: ". ")
}

// MARK: - Colours that carry meaning in both appearances

/// A colour as sRGB components, so the contrast it achieves is computed rather
/// than eyeballed.
public struct StoredDataColor: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// WCAG 2.1 relative luminance.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public func contrastRatio(against other: StoredDataColor) -> Double {
        let mine = relativeLuminance
        let theirs = other.relativeLuminance
        return (max(mine, theirs) + 0.05) / (min(mine, theirs) + 0.05)
    }
}

/// The two colours this screen uses to mean something, given for both grounds.
///
/// `Color.orange` and `Color.green` are tint colours, meant for fills. As body
/// copy on the light grouped background they measure 2.20:1 and 2.22:1 against
/// WCAG AA's 4.5:1 for text this size, so every warning here — that the total is
/// a floor rather than a figure, that a model's file is gone, that transcripts
/// cannot be opened, that no API key is required — reads clearly in dark mode
/// and is nearly invisible in light. The failure is invisible to anyone working
/// in dark mode, which is why the passing ratio is asserted in a test rather
/// than trusted to review.
public enum StoredDataPalette {
    /// A grouped list row: white in light, `#1C1C1E` in dark.
    public static let lightRowBackground = StoredDataColor(red: 1, green: 1, blue: 1)
    public static let darkRowBackground = StoredDataColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

    public static let warningOnLight = StoredDataColor(red: 0.698, green: 0.314, blue: 0)
    public static let warningOnDark = StoredDataColor(red: 1, green: 0.62, blue: 0.31)
    public static let successOnLight = StoredDataColor(red: 0, green: 0.45, blue: 0.26)
    public static let successOnDark = StoredDataColor(red: 0.35, green: 0.84, blue: 0.51)

    /// WCAG AA for body text. The warnings on this screen are `.caption` and
    /// `.footnote`, which is nowhere near the large-text exemption.
    public static let minimumTextContrast = 4.5
}

/// The byte string this app quotes everywhere, in one place so the inspector and
/// the sentences it builds cannot disagree about a number.
public func formattedByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
