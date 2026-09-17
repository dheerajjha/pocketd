import PocketdKit
import SwiftUI

/// The last screen, and the only one that has to earn anything.
///
/// Everything before it was a request. This is the receipt: a paragraph about
/// the reader's own day, assembled on the phone from the calendar and reminders
/// they granted two screens ago, sitting above a row that shows which of the
/// three are actually speaking. Nothing was sent anywhere to produce it and
/// nothing had to be downloaded first — the brain may still be arriving in the
/// card below, and the brief is already true.
///
/// The paragraph is `BriefPrompt.fallback`, the same template the Today tab
/// falls back to before a brain is resident. That is deliberate rather than a
/// shortcut: the simulator cannot hold a tool-capable model, most first runs are
/// still downloading at this point, and an intro whose final promise depends on
/// a generation that has not happened yet is an intro that ends in a spinner.
struct OnboardingDayStep: View {
    @Environment(AppModel.self) private var model

    var onOpen: () -> Void

    @State private var snapshot: TodaySnapshot?
    @State private var question = ""
    @State private var queued = false

    var body: some View {
        OnboardingPage(
            ornament: .icon("sun.max"),
            headline: "Here's your day.",
            secondary: "Written on this phone, from what you just connected.",
            primary: .init("Open Pocketd", run: onOpen)
        ) {
            VStack(alignment: .leading, spacing: PDSpacing.cardGap) {
                brief
                OnboardingConnectionsSummary(snapshot: snapshot)
                OnboardingBrainCard()
                askAhead
            }
        }
        .task {
            // Built once. A second read on every redraw would put an EventKit
            // query behind the scroll position.
            guard snapshot == nil else { return }
            snapshot = await OnboardingSnapshot.build(
                health: OnboardingSnapshot.healthAvailability(
                    enabled: model.healthToolsEnabled,
                    reported: model.healthAvailability
                )
            )
        }
    }

    // MARK: - The paragraph

    @ViewBuilder
    private var brief: some View {
        PDCard(warm: true) {
            VStack(alignment: .leading, spacing: PDSpacing.s) {
                SectionLabel("Today's brief")

                if let snapshot {
                    Text(
                        BriefPrompt.fallback(
                            snapshot: snapshot,
                            name: model.profile.greetingName,
                            now: Date()
                        )
                    )
                    .font(Font.pd.lead)
                    .foregroundStyle(Color.pd.ink)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Two bars rather than a spinner: the shape of what is
                    // coming, which is what stops the card resizing under the
                    // reader when the sentence lands.
                    VStack(alignment: .leading, spacing: PDSpacing.xs) {
                        placeholderLine(width: 1)
                        placeholderLine(width: 0.6)
                    }
                    .accessibilityLabel("Writing your brief")
                }
            }
        }
    }

    private func placeholderLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.pd.fillWarm)
            .frame(height: 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: width, y: 1, anchor: .leading)
            .pdShimmer()
    }

    // MARK: - The bridge

    /// A question asked while the brain is still coming down.
    ///
    /// The highest-leverage idea in the whole intro and the cheapest: the
    /// question goes into the same `IntentInbox` slot Siri and the Control
    /// Centre button use, and the shell collects it the instant it appears,
    /// sending it if a brain is already resident and leaving it in the box with
    /// the cursor after it if not. The wait becomes the first conversation
    /// rather than a blocker in front of one.
    private var askAhead: some View {
        VStack(alignment: .leading, spacing: PDSpacing.xs) {
            HStack(spacing: PDSpacing.xs) {
                Text("Ask me something. I'll answer the moment the brain is ready.")
                    .font(Font.pd.secondary)
                    .foregroundStyle(Color.pd.inkSecondaryWarm)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if queued {
                    StatusPill(.positive, "Queued")
                        .transition(.opacity)
                }
            }

            AskBar(
                text: $question,
                placeholder: "Ask me something…",
                canSend: !trimmedQuestion.isEmpty,
                // Nothing on this screen has asked for the microphone yet, and
                // a permission sheet on the last screen of an intro is how a
                // finished flow turns into one more request.
                showsMic: false,
                onSend: queue
            )
        }
        .animation(PDMotion.gentle, value: queued)
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func queue() {
        guard !trimmedQuestion.isEmpty else { return }
        IntentInbox.deliver(trimmedQuestion)
        question = ""
        queued = true
        Haptics.send()
    }
}

// MARK: - The three, at a glance

/// Calendar ✓ · Reminders ✓ · Health —
///
/// One row rather than three, because at this point the reader has already
/// answered each of them one screen at a time and what they want now is the
/// tally. A dash rather than a cross for the ones that are off: they said no,
/// which is a choice, and this app does not scold.
struct OnboardingConnectionsSummary: View {
    var snapshot: TodaySnapshot?

    var body: some View {
        HStack(spacing: PDSpacing.m) {
            entry("Calendar", snapshot?.calendar)
            entry("Reminders", snapshot?.reminders)
            entry("Health", snapshot?.health)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PDSpacing.xxs)
    }

    private func entry(_ name: String, _ availability: TodaySnapshot.Availability?) -> some View {
        let connected = availability?.isReadable == true
        return HStack(spacing: PDSpacing.xxs) {
            Image(systemName: connected ? "checkmark" : "minus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(connected ? Color.pd.positive : Color.pd.inkTertiary)
                // SF Symbols hands `minus` the label "Remove", which VoiceOver
                // then reads inside a row that is only reporting a state.
                .accessibilityHidden(true)
            MiniLabel(name, tint: connected ? .pd.ink : .pd.inkTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(connected ? "connected" : "not connected")")
    }
}

#Preview("Your day light") {
    OnboardingStepPreview {
        OnboardingDayStep(onOpen: {})
    }
    .environment(AppModel())
}

#Preview("Your day dark") {
    OnboardingStepPreview {
        OnboardingDayStep(onOpen: {})
    }
    .environment(AppModel())
    .preferredColorScheme(.dark)
}
