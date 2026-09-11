import Foundation
import Testing
@testable import PocketdKit

/// What the data inspector says, as against what it means to say.
///
/// Everything here is a claim rendered on a privacy screen whose whole argument
/// is that its details can be checked. A screen that prints a filename with a
/// hyphen in it that is not on disk, or a date as `Optional<Any>`, or a warning
/// in a colour nobody can read, has not lied about anything important — and has
/// taught the reader that the numbers beside it are decorative.
@Suite("Stored data presentation")
struct StoredDataPresentationTests {

    // MARK: - Identifiers are printed as they are stored

    @Test("a path gets break opportunities instead of an invented hyphen")
    func identifiersBreakWithoutHyphens() {
        // The file at the root of every iOS container, which rendered as
        // `…metadata.-plist` at the default text size because TextKit
        // hyphenates a token too long for its line.
        let real = ".com.apple.mobile_container_manager.metadata.plist"
        let shown = breakableIdentifier(real)

        #expect(shown != real, "without an inserted break there is nothing to stop the hyphen")
        #expect(strippingBreakOpportunities(shown) == real, "the token on screen must be the token on disk")
        #expect(shown.contains("-") == false)
        #expect(shown.contains(".\u{200B}com"))
        #expect(shown.contains("mobile_\u{200B}container"))
        #expect(shown.contains("metadata.\u{200B}plist"))
    }

    @Test("every separator a long key breaks at gets an opportunity")
    func everySeparatorBreaks() {
        #expect(strippingBreakOpportunities(breakableIdentifier("pocketd.autoOffloadInBackground"))
            == "pocketd.autoOffloadInBackground")
        #expect(breakableIdentifier("tmp/CFNetworkDownload_a1b2.tmp")
            == "tmp/\u{200B}CFNetworkDownload_\u{200B}a1b2.\u{200B}tmp")
        // A key with nothing to break at is handed back unchanged rather than
        // padded with invisible characters.
        #expect(breakableIdentifier("apiKey") == "apiKey")
        #expect(breakableIdentifier("") == "")
    }

    // MARK: - Preference values, as they are stored

    @Test("a stored date is shown as a date, not as the box it arrived in")
    func datesAreNamed() {
        // `pocketd.pairedAt` is a `Date` and matched none of the arms, so it
        // fell to a default that described `type(of: value)` — where `value` is
        // an `Any?`, which reports the Optional wrapper. The one key that says
        // when this phone was paired read `Optional<Any>` on every device.
        let paired = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = storedValueSummary(paired, forKey: "pocketd.pairedAt")

        #expect(summary.contains("Optional") == false)
        #expect(summary.contains("Any") == false)
        #expect(summary == paired.formatted(date: .abbreviated, time: .shortened))
    }

    @Test("an unhandled type names itself, which is what the fallback was for")
    func unhandledTypesNameThemselves() {
        #expect(storedValueSummary(URL(fileURLWithPath: "/tmp/x"), forKey: "whatever") == "URL")
        #expect(storedValueSummary(nil, forKey: "whatever") == "Empty")
    }

    @Test("the arms that already worked still work")
    func knownTypesAreUnchanged() throws {
        // Round-tripped through a property list, because that is the only thing
        // still separating `set(1, …)` from `set(true, …)` once it is on disk.
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["flag": true, "threads": 1] as [String: Any], format: .binary, options: 0
        )
        let read = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(storedValueSummary(try #require(read["flag"]), forKey: "flag") == "On")
        #expect(storedValueSummary(try #require(read["threads"]), forKey: "threads") == "1")
        #expect(storedValueSummary("short", forKey: "k") == "short")
        #expect(storedValueSummary(String(repeating: "a", count: 80), forKey: "k").hasSuffix("…"))
        #expect(storedValueSummary([1, 2, 3], forKey: "k") == "3 items")
        // The one entry holding a secret is named rather than dumped.
        let blob = storedValueSummary(Data(repeating: 0, count: 374), forKey: "pocketd.configuration")
        #expect(blob.contains("the API key"))
        #expect(blob.contains("374"))
    }

    // MARK: - Permissions, as VoiceOver hears them

    @Test("a permission row reads its reason, not only its state")
    func permissionsAnnounceTheirNote() {
        // HealthKit reports write authorization and refuses to report read
        // authorization, by design. "Not reported by iOS" with the reason
        // removed is indistinguishable from an app dodging the question — and
        // the combined row's label override was removing it.
        let note = "iOS never tells an app whether its request to read Health was allowed, so this screen cannot show it."
        let spoken = permissionAnnouncement(title: "Health", state: "Not reported by iOS", note: note)

        #expect(spoken.hasPrefix("Health: Not reported by iOS"))
        #expect(spoken.contains(note))
        // A row with nothing more to say does not get a dangling separator.
        #expect(permissionAnnouncement(title: "Calendar", state: "Allowed", note: nil) == "Calendar: Allowed")
    }

    // MARK: - Colours that carry meaning

    @Test("every warning on this screen is readable on both grounds")
    func warningsMeetContrast() {
        let pairs: [(String, StoredDataColor, StoredDataColor)] = [
            ("warning", StoredDataPalette.warningOnLight, StoredDataPalette.lightRowBackground),
            ("warning", StoredDataPalette.warningOnDark, StoredDataPalette.darkRowBackground),
            ("success", StoredDataPalette.successOnLight, StoredDataPalette.lightRowBackground),
            ("success", StoredDataPalette.successOnDark, StoredDataPalette.darkRowBackground),
        ]
        for (name, foreground, background) in pairs {
            let ratio = foreground.contrastRatio(against: background)
            #expect(
                ratio >= StoredDataPalette.minimumTextContrast,
                "\(name) measures \(ratio) on this ground, below WCAG AA for body text"
            )
        }
    }

    @Test("the system tints these replace are the reason the token exists")
    func systemTintsFailInLight() {
        // Not a test of Apple's colours — a test that the failure this token
        // fixes is real and is specifically a light-mode failure, which is why
        // it survived review by people working in dark mode.
        let systemOrange = StoredDataColor(red: 1, green: 0.584, blue: 0)
        let systemGreen = StoredDataColor(red: 0.204, green: 0.780, blue: 0.349)
        let onWhite = StoredDataPalette.lightRowBackground

        #expect(systemOrange.contrastRatio(against: onWhite) < StoredDataPalette.minimumTextContrast)
        #expect(systemGreen.contrastRatio(against: onWhite) < StoredDataPalette.minimumTextContrast)
        #expect(systemOrange.contrastRatio(against: StoredDataPalette.darkRowBackground) > 4.5)
    }

    @Test("relative luminance matches the definition it claims to implement")
    func luminanceIsWCAG() {
        // Anchors from the specification itself, so a transposed coefficient or
        // a dropped gamma step cannot pass.
        #expect(abs(StoredDataColor(red: 1, green: 1, blue: 1).relativeLuminance - 1) < 0.0001)
        #expect(abs(StoredDataColor(red: 0, green: 0, blue: 0).relativeLuminance) < 0.0001)
        let blackOnWhite = StoredDataColor(red: 0, green: 0, blue: 0)
            .contrastRatio(against: StoredDataColor(red: 1, green: 1, blue: 1))
        #expect(abs(blackOnWhite - 21) < 0.01)
    }
}
