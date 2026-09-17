import PocketdKit
import SwiftUI

/// What to say, and what to offer, when the brain on this phone cannot look
/// anything up.
///
/// A brain that cannot work a tool is a chat box with a good vocabulary. Ask it
/// "what's on tomorrow?" and it answers fluently and entirely from its own
/// imagination, because the calendar was never in front of it — the audit run
/// on this build got a paragraph about a religious festival in reply to a
/// question about a meeting. The app knew this and said so only in Settings
/// wording, under the two switches, in a sentence about registration and
/// context.
///
/// Three screens have to say it in words a person can act on — Ask's brain
/// chip, Ask's notice above the composer and Today's brief card — and all three
/// need the same way out, so the test, the sentence and the offer live here
/// once.
@MainActor
enum BrainUpgrade {

    /// A brain is resident and the engine is handing it no tools.
    ///
    /// `personalDataToolGate` is the engine's own verdict rather than the
    /// catalogue's claim, which matters for anything added through search: the
    /// catalogue has no opinion about those, and the gate has read the file.
    static func cannotReadYourDay(_ model: AppModel) -> Bool {
        model.loadedModelID != nil && !model.personalDataToolGate.registersTools
    }

    /// The sentence, in the plainest form that is still true.
    ///
    /// Not the Kit's `capabilityNotice`. That one is written for the Settings
    /// screen and says "nothing is registered and no context is spent on them.
    /// A 3B model or larger can", which is four pieces of jargon in a row on a
    /// screen whose rule is that there is none.
    static func sentence(for name: String) -> String {
        "\(name) cannot open your calendar, reminders or health, so anything it tells you about your day is a guess."
    }

    /// The cheapest brain in the built-in list that can work the tools and that
    /// this phone can actually hold — Qwen3 1.7B on any phone that fits it.
    ///
    /// Smallest rather than best, deliberately: this offer is being made to
    /// somebody who has already waited through one download, and the one they
    /// will take is the one that costs the least and ends the problem. Already
    /// installed ones are left out — there is nothing to fetch, and the useful
    /// destination in that case is the Brain screen, where Load lives.
    ///
    /// `nil` when no such brain fits, which is a real state on a small phone.
    /// Nothing is offered then, because an offer this app has already refused
    /// is worse than silence.
    static func offer(_ model: AppModel) -> ModelRecord? {
        ModelCatalog.all
            .filter { $0.toolSupport.isYes }
            // No vision brains: the projector doubles the download and this
            // offer is about reading a diary, not a photograph.
            .filter { !$0.declaredCapabilities.vision.isYes }
            .filter { !model.isInstalled($0) }
            .filter { model.fit(for: $0).isDownloadable }
            .min { $0.totalDownloadBytes < $1.totalDownloadBytes }
    }

    /// The label on the one-tap button. Named, because "Get a better one" tells
    /// nobody what is about to be downloaded or how big it is.
    static func offerTitle(_ record: ModelRecord) -> String {
        "Get \(record.displayName)"
    }
}

/// The callout the two screens share: the sentence, and the way out.
///
/// A view rather than two copies, because the copy and the button have to stay
/// the same on Today and on Ask — somebody who reads it in one place and acts
/// on it in the other must not find two different offers.
struct BrainUpgradeCallout: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator

    /// Shown under the sentence, for the screens that need a way to stop being
    /// told. `nil` leaves the callout permanent.
    var onDismiss: (() -> Void)?

    var body: some View {
        Callout(
            symbol: "exclamationmark.bubble",
            text: BrainUpgrade.sentence(for: model.loadedModelName),
            tint: .pd.caution,
            fill: .pd.cautionSoft
        ) {
            HStack(spacing: PDSpacing.s) {
                if let offer = BrainUpgrade.offer(model) {
                    LinkPill(title: BrainUpgrade.offerTitle(offer), symbol: "arrow.down") {
                        model.download(offer)
                    }
                } else {
                    LinkPill(title: "Choose a brain", symbol: "chevron.right") {
                        navigator.openYou(.brain)
                    }
                }
                Spacer(minLength: 0)
                if let onDismiss {
                    Button("OK") {
                        Haptics.tap()
                        onDismiss()
                    }
                    .font(Font.pd.secondary.weight(.medium))
                    .foregroundStyle(Color.pd.inkSecondary)
                    .buttonStyle(PDPressStyle())
                }
            }
        }
    }
}
