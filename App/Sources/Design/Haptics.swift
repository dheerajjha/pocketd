import SwiftUI
import UIKit

/// The five taps this app is allowed to make, and nothing else.
///
/// A closed set rather than a `UIImpactFeedbackGenerator` at every call site,
/// for the same reason the analytics events are an enum: the interesting
/// question is not "does this button buzz" but "does the whole app buzz
/// consistently", and that can only be read off one list.
///
/// The mapping is deliberate and it is the spec's:
///
/// - `.light` — a chip, a chevron, anything that only changes what is on screen.
/// - `.medium` — send. The one gesture that spends the phone's battery.
/// - `.success` — the brain finished loading, a reminder was set. Something
///   happened in the world.
/// - `.warning` — a refusal the user can act on.
/// - `.selection` — the tab changed.
///
/// `@MainActor` because every generator here is, and because haptics fired off
/// the main thread are silently dropped rather than reported.
@MainActor
enum Haptics {
    /// Kept alive rather than created per call. A generator allocated and
    /// released inside one function never gets to warm the Taptic Engine, and
    /// the first tap after a pause is late by enough to feel disconnected from
    /// the finger that caused it.
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notice = UINotificationFeedbackGenerator()
    private static let selection = UISelectionFeedbackGenerator()

    /// Whether to play anything at all.
    ///
    /// Reduce Motion is not a haptics setting, but a person who has asked for
    /// less movement is the same person for whom a buzzing phone is the
    /// problem. iOS has no separate "reduce haptics" accessibility flag to
    /// read, so this is the closest honest proxy.
    private static var isMuted: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    static func tap() {
        guard !isMuted else { return }
        light.impactOccurred()
    }

    static func send() {
        guard !isMuted else { return }
        medium.impactOccurred()
    }

    static func success() {
        guard !isMuted else { return }
        notice.notificationOccurred(.success)
    }

    static func warning() {
        guard !isMuted else { return }
        notice.notificationOccurred(.warning)
    }

    static func tabChanged() {
        guard !isMuted else { return }
        selection.selectionChanged()
    }

    /// Tell the Taptic Engine something is about to happen.
    ///
    /// Called on the gesture that precedes the feedback — a press that will
    /// become a tap, a drag that will end in a snap — so the engine is already
    /// powered when the moment arrives. Free to call and free to skip.
    static func prepare() {
        guard !isMuted else { return }
        light.prepare()
        medium.prepare()
        notice.prepare()
        selection.prepare()
    }
}
